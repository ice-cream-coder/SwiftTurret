import AVR

var bufferSize: Int = 256

// NEC Protocol Constants (in microseconds)
private let NEC_HEADER_MARK_MICROS: UInt32 = 9000
private let NEC_HEADER_SPACE_MICROS: UInt32 = 4500
private let NEC_BIT_MARK_MICROS: UInt32 = 560
private let NEC_ONE_SPACE_MICROS: UInt32 = 1690
private let NEC_ZERO_SPACE_MICROS: UInt32 = 560
private let NEC_REPEAT_SPACE_MICROS: UInt32 = 2250
private let NEC_TIMEOUT_MICROS: UInt32 = 110000 // Max duration of a full NEC frame + some buffer, or long gap
private let NEC_FRAME_END_GAP_MICROS: UInt32 = 10000 // Gap to signify end of frame for processing

// Timing Constants
private let MARK_EXCESS_MICROS: UInt32 = 100 // Compensation for demodulator distortion
private let TOLERANCE_PERCENT: UInt32 = 25 // Standard tolerance for IR protocols

class IRReceiver {

    static let `default` = IRReceiver(irPin: 9)

    private enum State {
        case idle
        case receiving
        case done
    }

    enum Command: UInt8  {
        case unknown = 0x00
        case up = 0x18
        case down = 0x52
        case left = 0x8
        case right = 0x5A
        case ok = 0x1C
        case _1 = 0x45
        case _2 = 0x46
        case _3 = 0x47
        case _4 = 0x44
        case _5 = 0x40
        case _6 = 0x43
        case _7 = 0x7
        case _8 = 0x15
        case _9 = 0x9
        case _0 = 0x19
        case star = 0x16
        case pound = 0xD
    }

    private var rawData = [UInt32](repeating: 0, count: &bufferSize) // Stores durations in MICROS
    private var currentIndex: Int = 0
    private var state: State = .idle
    private var onReceiveCallback: ((Command) -> Void)? // Callback for when a known command is decoded
    private var lastDecodedCommand: Command = .unknown // Store the last successfully decoded command

    private let irPin: Pin
    private var lastPinChangeMicros: UInt32 = 0 // Will store µs from accurateMicros()
    private var lastKnownPinState: Bool = false // Added to store the last known state

    private init(irPin: Pin) {
        self.irPin = irPin
        pinMode(pin: irPin, mode: INPUT)
        print("IR receiver starting on pin \(irPin)")

        // Initialize states for IR processing
        self.lastKnownPinState = digitalRead(pin: irPin)
        self.state = .idle
        self.currentIndex = 0
        self.lastPinChangeMicros = micros // Initialize with µs
    }

    // Renamed from user's timerInterruptHandler to update, and will modify
    private func _update() {
        let currentPinState = digitalRead(pin: irPin)
        defer {
            lastKnownPinState = currentPinState
        }
        switch state {
        case .idle:
            handleIdle(pinState: currentPinState)
        case .receiving:
            handleReceiving(pinState: currentPinState)
        case .done:
            handleDone() // Process data and reset
        }
    }

    private func handleIdle(pinState: Bool) {
        // An IR signal starts with a MARK (LOW signal level)
        // Looking for a falling edge (true -> false)
        if lastKnownPinState == true && pinState == false { // Start of a mark
            state = .receiving
            currentIndex = 0 // Reset buffer index for new signal
            lastPinChangeMicros = micros // Start timing the mark from now (in µs)
        }
    }

    private func handleReceiving(pinState: Bool) {
        let duration = micros - lastPinChangeMicros

        if pinState != lastKnownPinState { // Pin state changed, record duration of previous state
            if currentIndex < bufferSize {
                rawData[currentIndex] = duration
                currentIndex += 1
                lastPinChangeMicros = micros // Reset timer for the new state
            } else {
                // Buffer overflow
                print("IR Buffer Overflow")
                state = .done // Process what we have, or discard
                return
            }
        } else {
            // Pin state has not changed. Check for timeout (long space indicating end of transmission)
            // This is crucial for NEC, which ends with a final mark pulse followed by a long silence (gap).
            // We detect this gap if the current state (which should be a SPACE, i.e. pinState == true for active-low)
            // persists for too long.
            if pinState == true { // Currently in a space
                if duration > NEC_FRAME_END_GAP_MICROS { // Check for frame-ending gap first
                    state = .done
                }
            } else { // Currently in a mark
                 // If stuck in a mark for too long, could be an error or continuous signal not from a remote.
                 // For NEC, marks are short. If a mark is extremely long, might be noise or different protocol.
                 if duration > NEC_HEADER_MARK_MICROS + (NEC_HEADER_MARK_MICROS * TOLERANCE_PERCENT / 100) {
                     // This mark is too long even for an NEC header mark, potentially an error or noise.
                     print("Warning: Unusually long mark detected: \(duration) us")
                     state = .idle
                 }
            }
        }
    }


    private func handleDone() {
        // print("IR Done. Samples: \(currentIndex)")
        // for i in 0..<currentIndex {
        //     print("\(rawData[i]), ", addNewline: false)
        // }
        // print("")
        lastDecodedCommand = decodeCommand()
        if lastDecodedCommand != .unknown {
             onReceiveCallback?(lastDecodedCommand)
        } else {
            // print("Unknown command")
        }

        state = .idle
    }

    // Helper to match ticks (converted from micros) against expected micros with tolerance
    private func matchDuration(measuredMicros: UInt32, expectedMicros: UInt32, isMark: Bool) -> Bool {
        // Corrected compensation logic:
        // Marks are typically measured as longer due to demodulator stretch.
        // Spaces are typically measured as shorter.
        // We adjust the measuredMicros to compensate before comparing with the ideal expectedMicros.
        let compensatedMeasuredMicros: UInt32
        if isMark {
            // If measured mark is longer than actual, subtract excess from measured value.
            if measuredMicros > MARK_EXCESS_MICROS {
                compensatedMeasuredMicros = measuredMicros - MARK_EXCESS_MICROS
            } else {
                compensatedMeasuredMicros = 0 // Cannot be less than 0
            }
        } else {
            // If measured space is shorter than actual, add "excess" (which is effectively a deficit that was lost) to measured value.
            // Check for potential overflow, though MARK_EXCESS_MICROS is usually small.
            if measuredMicros <= UInt32.max - MARK_EXCESS_MICROS {
                compensatedMeasuredMicros = measuredMicros + MARK_EXCESS_MICROS
            } else {
                compensatedMeasuredMicros = UInt32.max // Clamp at max if overflow would occur
            }
        }

        let lower = expectedMicros - (expectedMicros * TOLERANCE_PERCENT / 100)
        let upper = expectedMicros + (expectedMicros * TOLERANCE_PERCENT / 100)

        // print("Matching: measured \(measuredMicros) (compensated: \(compensatedMeasuredMicros)) vs expected \(expectedMicros) [\(lower)-\(upper)]")
        return compensatedMeasuredMicros >= lower && compensatedMeasuredMicros <= upper
    }

    private func decodeCommand() -> Command {
        // Ensure we have enough data for at least a header
        // For NEC, rawData[0] is Header Mark, rawData[1] is Header Space or Repeat Space
        if currentIndex < 2 { // Not enough data for a header mark and a subsequent space
            // print("Not enough data for a header mark and space") // DEBUG
            return .unknown
        }

        // NEC Header Mark (approx 9ms)
        if !matchDuration(measuredMicros: rawData[0], expectedMicros: NEC_HEADER_MARK_MICROS, isMark: true) {
            print("NEC Decode: Header Mark mismatch. Got \(rawData[0]) us, expected \(NEC_HEADER_MARK_MICROS) us")
            return .unknown
        }

        // Check for NEC Repeat Code first (Header Mark + Repeat Space + Bit Mark)
        // A repeat code will have currentIndex == 3 (Header Mark, Repeat Space, Final Mark)
        if matchDuration(measuredMicros: rawData[1], expectedMicros: NEC_REPEAT_SPACE_MICROS, isMark: false) {
            if currentIndex == 3 && matchDuration(measuredMicros: rawData[2], expectedMicros: NEC_BIT_MARK_MICROS, isMark: true) {
                // print("NEC Repeat Code Detected!") // DEBUG
                return lastDecodedCommand // Return the last known command
            } else {
                // print("NEC Decode: Potential Repeat Code structure mismatch. currentIndex: \\(currentIndex)") // DEBUG
                return .unknown // Doesn't fit full repeat structure
            }
        }

        // If not a repeat code, try to decode as a full NEC command
        // NEC Header Space (approx 4.5ms)
        if !matchDuration(measuredMicros: rawData[1], expectedMicros: NEC_HEADER_SPACE_MICROS, isMark: false) {
            print("NEC Decode: Header Space mismatch. Got \(rawData[1]) us, expected \(NEC_HEADER_SPACE_MICROS) us")
            return .unknown
        }

        // print("NEC Header Detected for full command!") // DEBUG

        // NEC protocol has 32 bits of data after the header.
        // Each bit: MARK + SPACE. So, 32 * 2 = 64 entries in rawData for the data part.
        // Total entries needed: 2 (header) + 64 (data) = 66.
        if currentIndex < (2 + 32 * 2) {
            print("NEC Decode: Insufficient data for 32 bits. Got \(currentIndex) entries.")
            return .unknown // Not enough data for full message
        }

        var decodedValue: UInt32 = 0
        var rawIndex: Int = 2 // Start decoding bits from rawData[2]

        for i in 0..<32 { // 32 bits to decode
            // Each bit starts with a mark pulse
            let markDuration = rawData[rawIndex]
            if !matchDuration(measuredMicros: markDuration, expectedMicros: NEC_BIT_MARK_MICROS, isMark: true) {
                // print("NEC Decode: Bit \(i) Mark mismatch. Got \(markDuration) us")
                return .unknown // Mark timing error
            }
            rawIndex += 1

            // Followed by a space pulse, whose duration determines the bit value
            let spaceDuration = rawData[rawIndex]
            let bit: UInt32
            if matchDuration(measuredMicros: spaceDuration, expectedMicros: NEC_ONE_SPACE_MICROS, isMark: false) {
                bit = 1
            } else if matchDuration(measuredMicros: spaceDuration, expectedMicros: NEC_ZERO_SPACE_MICROS, isMark: false) {
                bit = 0
            } else {
                // print("NEC Decode: Bit \(i) Space mismatch. Got \(spaceDuration) us")
                return .unknown // Space timing error
            }
            rawIndex += 1

            // NEC transmits LSB first. We construct the decodedValue with LSB at bit 0.
            decodedValue |= (bit << i)
        }

        // print("NEC Decoded Value: 0x\(String(decodedValue, radix: 16))")

        // Extract address and command bytes
        // NEC format: Address (8 bits), Inverted Address (8 bits), Command (8 bits), Inverted Command (8 bits)
        let address = UInt8((decodedValue >> 0) & 0xFF)
        let invAddress = UInt8((decodedValue >> 8) & 0xFF)
        let commandByte = UInt8((decodedValue >> 16) & 0xFF)
        let invCommandByte = UInt8((decodedValue >> 24) & 0xFF)

        // Validate address and command (inverted bytes must be logical NOT of original)
        if address != (invAddress ^ 0xFF) || commandByte != (invCommandByte ^ 0xFF) {
            print("NEC Decode: Address or Command checksum failed.")
            // print("Addr: 0x\(String(address, radix: 16)), InvAddr: 0x\(String(invAddress, radix: 16))")
            // print("Cmd: 0x\(String(commandByte, radix: 16)), InvCmd: 0x\(String(invCommandByte, radix: 16))")
            return .unknown
        }

        // print("NEC Decode Success: Addr=0x\(String(address, radix: 16)), Cmd=0x\(String(commandByte, radix: 16))")

        // Map commandByte to Command enum
        if let newCommand = Command(rawValue: commandByte),
            newCommand != .unknown {
            return newCommand
        } else {
            return .unknown
        }
    }

    // MARK: - Public API

    /// Set the callback for when a command is received.
    /// This method must only be called once.
    ///
    /// - Parameter callback: The callback to be called when a command is received.
    func onReceive(_ callback: @escaping (Command) -> Void) {
        onReceiveCallback = callback
    }

    /// Update the IR receiver.
    ///
    /// This method must be called in the main loop.
    func update() {
        _update()
    }
}
