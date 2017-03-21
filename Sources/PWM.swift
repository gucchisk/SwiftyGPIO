/*
   SwiftyGPIO

   Copyright (c) 2016 Umberto Raimondi
   Licensed under the MIT license, as follows:

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in all
   copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
   SOFTWARE.)
*/
#if os(Linux)
    import Glibc
#else
    import Darwin.C
#endif

extension SwiftyGPIO {

    public static func hardwarePWMs(for board: SupportedBoard) -> [Int:[GPIOName:PWMOutput]]? {
        switch board {
        case .RaspberryPiRev1:
            fallthrough
        case .RaspberryPiRev2:
            fallthrough
        case .RaspberryPiPlusZero:
            return PWMRPI1
        case .RaspberryPi2:
            return PWMRPI23
        default:
            return nil
        }
    }
}

// MARK: - SPI Presets
extension SwiftyGPIO {

    // RaspberryPis ARMv6 (all 1, Zero, Zero W) PWMs, only accessible ones, divided in channels (can use only one for each channel)
    static let PWMRPI1: [Int:[GPIOName:PWMOutput]] = [
        0: [.P12: HardwarePWM(gpioId: 12, alt: 0, channel:0, baseAddr: 0x20000000), .P18: HardwarePWM(gpioId: 18, alt: 5, channel:0, baseAddr: 0x20000000)],
        1: [.P13: HardwarePWM(gpioId: 13, alt: 0, channel:1, baseAddr: 0x20000000), .P19: HardwarePWM(gpioId: 19, alt: 5, channel:1, baseAddr: 0x20000000)]
    ]

    // RaspberryPis ARMv7 (2-3) PWMs, only accessible ones, divided in channels (can use only one for each channel)
    static let PWMRPI23: [Int:[GPIOName:PWMOutput]] = [
        0: [.P12: HardwarePWM(gpioId: 12, alt: 0, channel:0, baseAddr: 0x3F000000), .P18: HardwarePWM(gpioId: 18, alt: 5, channel:0, baseAddr: 0x3F000000)],
        1: [.P13: HardwarePWM(gpioId: 13, alt: 0, channel:1, baseAddr: 0x3F000000), .P19: HardwarePWM(gpioId: 19, alt: 5, channel:1, baseAddr: 0x3F000000)]
    ]
}

// MARK: PWM

public protocol PWMOutput {
    func initPWM()
    func startPWM(period ns: Int, duty percent: Int)
    func stopPWM()
}

public class HardwarePWM: PWMOutput {
    let gpioId: UInt
    let alt: UInt
    let channel: Int

    let BCM2708_PERI_BASE: Int
    let GPIO_BASE: Int  // GPIO Register
    let PWM_BASE: Int   // PWM Register
    let CLOCK_BASE: Int // Clock Manager Register
    let BCM2708_PHY_BASE: Int = 0x7e000000
    let PWM_PHY_BASE: Int
    let PWMDMA = 5

    var gpioBasePointer: UnsafeMutablePointer<UInt>!
    var pwmBasePointer: UnsafeMutablePointer<UInt>!
    var clockBasePointer: UnsafeMutablePointer<UInt>!
    var dmaBasePointer: UnsafeMutablePointer<UInt>!
    var dma_cb: UnsafeMutablePointer<DMACallback>! = nil
    var pwm_raw: UnsafeMutablePointer<UInt>! = nil
    var mailbox: MailBox! = nil

    var zeroPattern: Int = 0
    var onePattern: Int = 0
    var symbolBits: Int = 0
    var patternFrequency: Int = 0
    var patternDelay: Int = 0

    public init(gpioId: UInt, alt: UInt, channel: Int, baseAddr: Int, dmanum: Int = 5) { //PWMDMA
        self.gpioId = gpioId
        self.alt = alt
        self.channel = channel
        BCM2708_PERI_BASE = baseAddr
        GPIO_BASE = BCM2708_PERI_BASE + 0x200000  // GPIO Register
        PWM_BASE =  BCM2708_PERI_BASE + 0x20C000  // PWM Register
        CLOCK_BASE = BCM2708_PERI_BASE + 0x101000 // Clock Manager Register
        PWM_PHY_BASE = BCM2708_PHY_BASE + 0x20C000 // PWM controller physical address
    }

    /// Init PWM on this pin, set alternative function
    public func initPWM() {
        var mem_fd: Int32 = 0

        //Try to open one of the mem devices
        for device in ["/dev/gpiomem", "/dev/mem"] {
            mem_fd=open(device, O_RDWR | O_SYNC)
            if mem_fd>0 {
                break
            }
        }
        guard mem_fd > 0 else {
            fatalError("Can't open /dev/mem , use sudo!")
        }

        gpioBasePointer = memmap(from: mem_fd, at: GPIO_BASE)
        pwmBasePointer = memmap(from: mem_fd, at: PWM_BASE)
        clockBasePointer = memmap(from: mem_fd, at: CLOCK_BASE)

        let DMAOffsets: [Int] = [0x00007000, 0x00007100, 0x00007200, 0x00007300,
                         0x00007400, 0x00007500, 0x00007600, 0x00007700,
                         0x00007800, 0x00007900, 0x00007a00, 0x00007b00,
                         0x00007c00, 0x00007d00, 0x00007e00, 0x00e05000]

        func dmanumToPhysicalAddress(_ dmanum: Int) -> Int {
            guard dmanum < DMAOffsets.count else { return 0 }
            return BCM2708_PERI_BASE + DMAOffsets[dmanum]
        }

        var dma_addr = dmanumToPhysicalAddress(PWMDMA) // Address of a specific DMA Channel registers set
        let pageOffset = dma_addr % PAGE_SIZE
        dma_addr -= pageOffset

        let dma_map = UnsafeMutableRawPointer(memmap(from: mem_fd, at: dma_addr))
        dmaBasePointer = (dma_map + pageOffset).assumingMemoryBound(to: UInt.self)

        close(mem_fd)

        // set PWM alternate function for this GPIO
        setAlt()
    }

    /// Start a PWM signal with specific period in ns and duty cycle from 0 to 100.
    /// The signal starts, asynchronously(manged by a device external to the CPU), once this method is called and 
    /// needs to be stopped manually calling `stopPWM()`.
    public func startPWM(period ns: Int, duty percent: Int) {
        // Kill the clock
        clockBasePointer.advanced(by: 40).pointee = CLKM_PASSWD | CLKM_CTL_KILL     //CM CTL register: Set KILL flag
        usleep(10)

        // If the required frequency is too high, this value reduces the number of samples (scale does the opposite)
        let highFreqSampleReduction: UInt = (ns < 750) ? 10 : 1

        let freq: UInt = (1_000_000_000/UInt(ns)) * 100 / highFreqSampleReduction
        let (idiv, scale) = calculateDIVI(base: .PLLD, desired: freq)                               //Using the faster (with known freq) available clock to reduce jitter

        // Configure the clock and divisor that will be used to generate the signal
        clockBasePointer.advanced(by: 41).pointee = CLKM_PASSWD | (idiv << CLKM_DIV_DIVI)            //CM CTL DIV register: Set DIVI value 
        clockBasePointer.advanced(by: 40).pointee = CLKM_PASSWD | CLKM_CTL_ENAB | CLKM_CTL_SRC_PLLD  //CM CTL register: Enable clock, MASH 0, source PLLD /////////////0x16
        pwmBasePointer.pointee = 0                                                                   //PWM CTL register: Everything at 0, enable flag included, disables previous PWM
        usleep(10)
        // Configure the parameters for the M/S algorithm, S the number of total slots in RNG1 and M the number of slots with high value in DAT1
        let RNG = (channel == 0) ? 4 : 8
        let DAT = (channel == 0) ? 5 : 9
        pwmBasePointer.advanced(by: RNG).pointee = 100 * scale / highFreqSampleReduction                                    //RNG1 register
        pwmBasePointer.advanced(by: DAT).pointee = UInt((Float(percent) / Float(highFreqSampleReduction)) * Float(scale))   //DAT1 register
        let PWMCTL_MSEN = (channel == 0) ? PWMCTL_MSEN1 : PWMCTL_MSEN2
        let PWMCTL_PWEN = (channel == 0) ? PWMCTL_PWEN1 : PWMCTL_PWEN2
        pwmBasePointer.pointee = PWMCTL_MSEN | PWMCTL_PWEN                                                              //PWM CTL register, channel enabled, M/S mode
    }

    public func stopPWM() {
        pwmBasePointer.pointee = 0      //PWM CTL register, everything at 0, enable flag included
    }

    /// Maps a block of memory and returns the pointer
    internal func memmap(from mem_fd: Int32, at offset: Int) -> UnsafeMutablePointer<UInt> {
        let m = mmap(
            nil,                 //Any adddress in our space will do
            BLOCK_SIZE,          //Map length
            PROT_READ|PROT_WRITE,// Enable reading & writting to mapped memory
            MAP_SHARED,          //Shared with other processes
            mem_fd,              //File to map
            off_t(offset)     //Offset to GPIO peripheral
            )!

        if (unsafeBitCast(m, to: Int.self) == -1) {    //MAP_FAILED not available, but its value is (void*)-1
            perror("mmap error")
            abort()
        }
        let pointer = m.assumingMemoryBound(to: UInt.self)

        return pointer
    }

    /// Set the alternative function for this GPIO
    internal func setAlt() {
        let altid = (self.alt<=3) ? self.alt+4 : self.alt==4 ? 3 : 2
        let ptr = gpioBasePointer.advanced(by: Int(gpioId/10))       // GPFSELn 0..5
        ptr.pointee &= ~(7<<((gpioId%10)*3))
        ptr.pointee |=  (altid<<((gpioId%10)*3))
    }

    /// Calculate the DIVI value that will divide the selected base clock frequency to obtain the desired frequency.
    ///
    /// For low frequencies, the DIVI value is calculated again increasing the scale value until an acceptable value 
    /// for the divisor is found. DIVI should be smaller than half the maximum value (0x1000) to reduce jitter.
    /// The scale value (increased by 10 every time the DIVI value is too high) will be used to increase the number 
    /// of samples generated by the M/S algorithm.
    ///
    /// - Parameter base: base clock that will be used to generate the signal
    ///
    /// - Parameter desired: desired target frequency
    ///
    /// - Returns: divi divisor value, and scale value as a multiple of ten
    ///
    internal func calculateDIVI(base: ClockSource, desired: UInt) -> (divi: UInt, scale: UInt) {
        var divi: UInt = base.rawValue/desired
        var scale: UInt = 1

        while divi > 0x800 {
            // Divisor too high (greater then half the limit), would not be generated properly
            scale *= 10
            divi = base.rawValue/(desired*scale)
        }
        if divi < 1 {
            divi = 1
        }
        return (divi, scale)
    }

    /// Calculate the unscaled DIVI value that will divide the selected base clock frequency to obtain the desired frequency.
    /// The resulting divisor doesn't take advantage of a scaling factor, for higher DIVI values the resulting signal could
    /// have high distortion.
    ///
    /// - Parameter base: base clock that will be used to generate the signal
    ///
    /// - Parameter desired: desired target frequency
    ///
    /// - Returns: divi divisor value
    ///
    internal func calculateUnscaledDIVI(base: ClockSource, desired: UInt) -> UInt{
        var divi: UInt = base.rawValue/desired

        if divi > 0x1000 {
            // Divisor too high (greater then half the limit), would not be generated properly
            divi = 0x1000
        }

        if divi < 1 {
            divi = 1
        }
        return divi
    }
}

/// Pattern base PWM
extension HardwarePWM {

    /// Start the DMA feeding the PWM FIFO.  This will stream the entire DMA buffer out of both PWM channels.
    internal func dma_start(dmaCallback address: UInt) {
        dmaBasePointer.pointee = DMACS_RESET
        usleep(10)
        dmaBasePointer.pointee = DMACS_INT | DMACS_END
        dmaBasePointer.advanced(by: 1).pointee  = address    //CONBLK_AD
        dmaBasePointer.advanced(by: 8).pointee = 7           //DEBUG: clear debug error flags
        dmaBasePointer.pointee = DMACS_WAIT_OUTSTANDING_WRITES | (15 << DMACS_PANIC_PRIORITY) | (15 << DMACS_PRIORITY) | DMACS_ACTIVE
    }

    /// Wait for any executing DMA operation to complete before returning.
    internal func dma_wait() {
        while (dmaBasePointer.pointee & DMACS_ACTIVE > 0) && !(dmaBasePointer.pointee & DMACS_ERROR > 0) {
            usleep(10)
        }

        if (dmaBasePointer.pointee & DMACS_ERROR)>0 {
            fatalError("DMA Error: \(dmaBasePointer.advanced(by: 8).pointee)")
        }
    }

    internal func waitOnSendData() {
        dma_wait()
    }

    internal func clearPattern() {
        dma_wait()
        // Stop PWM and clock
        pwmBasePointer.pointee = 0
        usleep(10)
        // stop clock and waiting for busy flag doesn't work, so kill clock
        clockBasePointer.advanced(by: 40).pointee = CLKM_PASSWD | CLKM_CTL_KILL     //Set KILL flag
        usleep(10)

        mailbox.cleanup()
    }

    internal func initPWMPattern(bytes count: Int, at frequency: Int, with resetDelay: Int, dutyzero: Int, dutyone: Int) {

        (zeroPattern,onePattern,symbolBits) = getRepresentation(zero: dutyzero, one: dutyone) 
        guard symbolBits > 0 else {fatalError("Couldn't generate a valid pattern for the provided duty cycle values, try with more spaced values.")}
        
        patternFrequency = frequency
        patternDelay = resetDelay

        // Round to the next 32 bit size
        let dataSize = (( ((count * 3 * 8 * symbolBits) + ((patternDelay * (patternFrequency * symbolBits)) / 1000000)) / 8) & ~0x3) + 4
        let size = dataSize + MemoryLayout<DMACallback>.stride

        // Round up to page size multiple
        let mboxsize = (size + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)
        mailbox = MailBox(handle: -1, size: mboxsize, isRaspi2: BCM2708_PERI_BASE != 0x20000000)

        guard let mailbox = mailbox else {fatalError("Could allocate mailbox.")}

        dma_cb = mailbox.baseVirtualAddress.assumingMemoryBound(to: DMACallback.self)
        pwm_raw = (mailbox.baseVirtualAddress + MemoryLayout<DMACallback>.stride).assumingMemoryBound(to: UInt.self)

        // Fill PWM buffer with zeros
        let rows = (mboxsize - MemoryLayout<DMACallback>.stride) / MemoryLayout<UInt>.stride
        for pos in 0..<rows {
            pwm_raw.advanced(by: pos).pointee = 0
        }
    }

    internal func sendDataWithPattern(values: [UInt8]) {

        guard symbolBits > 0 else {fatalError("Couldn't generate a valid pattern for the provided duty cycle values, try with more spaced values.")}

        // Stop PWM and clock
        pwmBasePointer.pointee = 0
        usleep(10)
        // stop clock and waiting for busy flag doesn't work, so kill clock
        clockBasePointer.advanced(by: 40).pointee = CLKM_PASSWD | CLKM_CTL_KILL     //Set KILL flag
        usleep(10)

        //Configure clock
        let idiv = calculateUnscaledDIVI(base: .Oscillator, desired: UInt(symbolBits * patternFrequency))
        clockBasePointer.advanced(by: 41).pointee = CLKM_PASSWD | (idiv << CLKM_DIV_DIVI)            //Set DIVI value  
        clockBasePointer.advanced(by: 40).pointee = CLKM_PASSWD | CLKM_CTL_ENAB | CLKM_CTL_SRC_OSC  //Enable clock, MASH 0, source PLLD /////////////0x16
        usleep(10)

        // Setup the PWM, use delays as the block is rumored to lock up without them.  Make
        // sure to use a high enough priority to avoid any FIFO underruns, especially if
        // the CPU is busy doing lots of memory accesses, or another DMA controller is
        // busy.  The FIFO will clock out data at a much slower rate (2.6Mhz max), so
        // the odds of a DMA priority boost are extremely low.

        pwmBasePointer.advanced(by: 4).pointee = 32  // RNG1: 32-bits per word to serialize
        usleep(10)
        pwmBasePointer.pointee = PWMCTL_CLRF1 //Correct?
        usleep(10)
        pwmBasePointer.advanced(by: 2).pointee = PWMDMAC_ENAB | 7 << PWMDMAC_PANIC | 3 << PWMDMAC_DREQ
        usleep(10)
        pwmBasePointer.pointee = PWMCTL_USEF1 | PWMCTL_MODE1 //| PWMCTL_USEF2 | PWMCTL_MODE2 //??????
        usleep(10)
        pwmBasePointer.pointee |= PWMCTL_PWEN1 //| PWMCTL_PWEN2

        // Initialize the DMA control block 
        let transferSize = mailbox.size - MemoryLayout<DMACallback>.stride
        dma_cb.pointee = DMACallback(
                ti: DMATI_NO_WIDE_BURSTS |   // 32-bit transfers
                     DMATI_WAIT_RESP |       // wait for write complete
                     DMATI_DEST_DREQ |       // user peripheral flow control
                     UInt32(0x5  << DMATI_PERMAP) |       // PWM peripheral
                     DMATI_SRC_INC,          // Increment src addr
                source_ad: UInt32(mailbox.virtualTobaseBusAddress(UnsafeMutableRawPointer(pwm_raw))),
                dest_ad: UInt32(PWM_PHY_BASE + 0x18),         // PWM FIF1 Register, shared between channels
                txfr_len: UInt32(transferSize),
                stride: 0,
                nextconbk: 0)

        dmaBasePointer.pointee = 0              //0 CS
        dmaBasePointer.advanced(by: 5).pointee = 0  //0 TXFR_LEN

        let stream = dataToBitStream(data: values, zero: zeroPattern, one: onePattern, width: symbolBits)

        func printBinary(_ value: UInt32) {
            var res = ""
            for i in (0...31).reversed() {
                res += ((value & (1 << UInt32(i))) > 0) ? "1" : "0"
            }
            print(res)
        }

        for idx in 0..<stream.count {
            printBinary(stream[idx])
            pwm_raw[idx] = UInt(stream[idx])
        }

        // Wait for any previous DMA operation to complete.
        dma_wait()
        dma_start(dmaCallback: mailbox.virtualTobaseBusAddress(mailbox.baseVirtualAddress))
    }

    /// Calculate an approximated bit pattern representation n-bits wide and filled with ones from the left with the given % value.
    /// The width of the pattern is calculated as the smaller one for which the representation of zero and one differ.
    /// Possible width starting from 3 bits to 16, try to adjust your percentage levels to have the smaller possible patterns.
    ///
    /// Pattern at 33% with width 3 bits: 100
    /// Pattern at 60% with width 3 bits: 110
    /// Pattern at 10% with width 8 bits: 10000000
    /// Pattern at 12% with width 8 bits: 10000000
    /// Pattern at 20% with width 8 bits: 11000000
    /// 
    /// - Parameter zero: percentage of fill for the zero value
    /// - Parameter one: percentage of fill for the one value
    /// 
    /// - Returns: patterns for zero and one and first acceptable bit width
    ///
    private func getRepresentation(zero: Int, one: Int) -> (zero: Int, one: Int, width: Int) {
        for size in 3...16 {
            let (z,o) = getRepresentation(zero: zero, one: one, bits: size)
            if (z ^ o) > 0 {
                return (z,o,size)
            }
        }
        return (0,0,0)
    }

    /// Calculate an approximated bit pattern representation n-bits wide and filled with ones from the left with the given % value
    ///
    /// Pattern at 33% with width 3 bits: 100
    /// Pattern at 60% with width 3 bits: 110
    /// Pattern at 10% with width 8 bits: 10000000
    /// Pattern at 12% with width 8 bits: 10000000
    /// Pattern at 20% with width 8 bits: 11000000
    /// 
    /// - Parameter zero: percentage of fill for the zero value
    /// - Parameter one: percentage of fill for the one value
    /// - Parameter bits: number of bits that will be used to generate the bit pattern
    /// 
    /// - Returns: patterns for zero and one
    ///
    private func getRepresentation(zero: Int, one: Int, bits: Int) -> (zero: Int, one: Int) {
        // Mask to extract only the n-bits value we want from the final result
        let mask = (1 << bits) - 1

        // How many bits must be at 1 for the zero and one bit pattern
        var z = Int((Float(zero) * Float(bits)/100).rounded(.toNearestOrAwayFromZero))
        z = (z == 0) ? 1 : z 
        var o = Int((Float(one) * Float(bits)/100).rounded(.toNearestOrAwayFromZero))
        o = (o == 0) ? 1 : o 

        // To get the pattern we want:
        // 1 << (bit_width - number_of_ones) , this gets us a 1 at the position number_of_ones+1, everything else unset
        // the_above - 1 , this gets us the specular mask that we'll negate and than mask
        z = ~((1 << (bits - z)) - 1) & mask
        o = ~((1 << (bits - o)) - 1) & mask

        return (z,o)
    }

    /// Convert each bit component of the data to a n bit representation
    private func dataToBitStream(data: [UInt8], zero: Int, one: Int, width: Int ) -> [UInt32] {
        var output = [UInt32]()
        var buffer: UInt32 = 0
        var bufferPos: UInt32 = 31

        for byte in data {
            // For each bit of the output, convert in signal bits
            for i in (0...7).reversed() {
                // Obtain the bit set that will be saved in appended to output, one bit at a time
                let s: Int = ((byte & (1 << UInt8(i))) > 0) ? one : zero

                // Add one bit at a time to the buffer, when it's full save it to the output and start from position 0
                for b in (0..<width).reversed() {
                    buffer &= ~(1 << bufferPos)
                    buffer |= (UInt32((s & (1 << b))>0 ? 1 : 0) << bufferPos)
                    if bufferPos == 0 {
                        output.append(buffer)
                        bufferPos = 31
                        buffer = 0
                    } else {
                        bufferPos -= 1
                    }
                }
            }
        }
        // Append the last partial element
        if bufferPos < 31 {
            output.append(buffer)
        }

        return output
    }

}

// MARK: - PWM Contants

// Constants for the Clock Manager General Purpose Control Register
let CLKM_PASSWD: UInt = 0x5A000000
let CLKM_CTL_KILL: UInt = (1 << 5)
let CLKM_CTL_ENAB: UInt = (1 << 4)
let CLKM_CTL_SRC_OSC: UInt = 1    // 19.2 MHz oscillator
let CLKM_CTL_SRC_PLLA: UInt = 4   // ~393.216 MHz PLLA (Audio)
let CLKM_CTL_SRC_PLLC: UInt = 5   // 1000 MHz PLLC (changes with overclock settings)
let CLKM_CTL_SRC_PLLD: UInt = 6   // 500 MHz  PLLD
let CLKM_CTL_SRC_HDMI: UInt = 7   // 216 MHz  HDMI auxiliary
// Constants for the Clock Manager General Purpose Divisors Register
let CLKM_DIV_DIVI: UInt = 12
let CLKM_DIV_DIVF: UInt = 0
// Constants for the PWM Control Register
let PWMCTL_MSEN2: UInt =  (1 << 15)
// No PWMCTL_CLRF2, the FIFO is shared
let PWMCTL_USEF2: UInt =  (1 << 13)
let PWMCTL_POLA2: UInt =  (1 << 12)
let PWMCTL_SBIT2: UInt =  (1 << 11)
let PWMCTL_RPTL2: UInt =  (1 << 10)
let PWMCTL_MODE2: UInt =  (1 << 9)
let PWMCTL_PWEN2: UInt =  (1 << 8)
let PWMCTL_MSEN1: UInt =  (1 << 7)
let PWMCTL_CLRF1: UInt =  (1 << 6)
let PWMCTL_USEF1: UInt =  (1 << 5)
let PWMCTL_POLA1: UInt =  (1 << 4)
let PWMCTL_SBIT1: UInt =  (1 << 3)
let PWMCTL_RPTL1: UInt =  (1 << 2)
let PWMCTL_MODE1: UInt =  (1 << 1)
let PWMCTL_PWEN1: UInt =  (1 << 0)

// Clock sources
// 0     0 Hz     Ground
// 1     19.2 MHz oscillator
// 2     0 Hz     testdebug0
// 3     0 Hz     testdebug1
// 4     ~393.216 MHz PLLA (Audio)
// 5     1000 MHz PLLC (changes with overclock settings)
// 6     500 MHz  PLLD
// 7     216 MHz  HDMI auxiliary
// 8-15  0 Hz     Ground
enum ClockSource: UInt {
    case Oscillator = 19200000
    case PLLA = 393216000
    case PLLC = 1000000000
    case PLLD = 500000000
    case HDMI = 216000000
}

// DMA Register
let DMACS_RESET: UInt = (1 << 31)
let DMACS_ABORT: UInt = (1 << 30)
let DMACS_WAIT_OUTSTANDING_WRITES: UInt = (1 << 28)
let DMACS_PANIC_PRIORITY: UInt = 20 // <<              
let DMACS_PRIORITY: UInt = 16 // <<
let DMACS_ERROR: UInt = (1 << 8)
let DMACS_INT: UInt = (1 << 2)
let DMACS_END: UInt = (1 << 1)
let DMACS_ACTIVE: UInt = (1 << 0)

/*
 * DMA Control Block in Main Memory
 *
 * Note: Must start at a 256 byte aligned address.
 *       Use corresponding register field definitions.
 */
struct DMACallback {
    let ti: UInt32
    let source_ad: UInt32
    let dest_ad: UInt32
    let txfr_len: UInt32
    let stride: UInt32
    let nextconbk: UInt32
    let reserv1: UInt32 = 0
    let reserv2: UInt32 = 0
}

// PWM DMAC Register
let PWMDMAC_ENAB: UInt =  (1 << 31)
let PWMDMAC_PANIC: UInt = 8
let PWMDMAC_DREQ: UInt = 0

// DMA Register
let DMATI_NO_WIDE_BURSTS: UInt32 =  (1 << 26)
let DMATI_PERMAP: UInt32 =  16
let DMATI_SRC_INC: UInt32 = (1 << 8)
let DMATI_DEST_DREQ: UInt32 = (1 << 6)
let DMATI_WAIT_RESP: UInt32 = (1 << 3)

