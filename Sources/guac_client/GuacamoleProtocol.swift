import Foundation

struct GuacInstruction: Sendable {
    let opcode: String
    let args: [String]
}

struct GuacProtocolParser: Sendable {
    /// Buffered bytes, not Characters: Guacamole length prefixes count UTF-8
    /// code units, so indexing by Character would desync the reader on any
    /// non-ASCII value (clipboard text, window titles).
    private var buffer: [UInt8] = []

    private static let dot = UInt8(ascii: ".")
    private static let comma = UInt8(ascii: ",")
    private static let semicolon = UInt8(ascii: ";")

    mutating func receive(_ text: String) -> [GuacInstruction] {
        buffer.append(contentsOf: Array(text.utf8))
        var instructions: [GuacInstruction] = []

        while let instruction = parseNext() {
            instructions.append(instruction)
        }

        return instructions
    }

    private mutating func parseNext() -> GuacInstruction? {
        var elements: [String] = []
        var position = 0

        while position < buffer.count {
            // Read the length prefix
            guard let dotIndex = buffer[position...].firstIndex(of: Self.dot) else {
                return nil // Need more data
            }

            guard let length = Int(String(decoding: buffer[position..<dotIndex], as: UTF8.self)),
                  length >= 0 else {
                // Malformed — resync past the next instruction terminator
                if let semi = buffer[position...].firstIndex(of: Self.semicolon) {
                    buffer.removeFirst(semi + 1)
                }
                return nil
            }

            let valueStart = dotIndex + 1
            let valueEnd = valueStart + length
            guard valueEnd < buffer.count else {
                return nil // Need the value plus its separator
            }

            elements.append(String(decoding: buffer[valueStart..<valueEnd], as: UTF8.self))

            let separator = buffer[valueEnd]
            position = valueEnd + 1

            if separator == Self.semicolon {
                // Instruction complete
                buffer.removeFirst(position)
                guard let opcode = elements.first else { return nil }
                return GuacInstruction(opcode: opcode, args: Array(elements.dropFirst()))
            } else if separator == Self.comma {
                // More arguments follow
                continue
            } else {
                // Unexpected character — discard what we've consumed
                buffer.removeFirst(position)
                return nil
            }
        }

        return nil
    }
}

enum GuacProtocolEncoder {
    static func encode(opcode: String, args: [String]) -> String {
        // Guacamole length prefixes count UTF-8 code units, not Swift
        // Characters. These differ for any non-ASCII value (accented letters in
        // a password, curly quotes in clipboard text, emoji), and a short
        // prefix desyncs guacd's reader mid-instruction — it closes the socket
        // with no error instruction.
        var parts = ["\(opcode.utf8.count).\(opcode)"]
        for arg in args {
            parts.append("\(arg.utf8.count).\(arg)")
        }
        return parts.joined(separator: ",") + ";"
    }

    static func key(keysym: Int, pressed: Bool) -> String {
        encode(opcode: "key", args: [String(keysym), pressed ? "1" : "0"])
    }

    static func mouse(x: Int, y: Int, buttonMask: Int) -> String {
        encode(opcode: "mouse", args: [String(x), String(y), String(buttonMask)])
    }

    static func size(width: Int, height: Int, dpi: Int) -> String {
        encode(opcode: "size", args: [String(width), String(height), String(dpi)])
    }

    static func sync(timestamp: String) -> String {
        encode(opcode: "sync", args: [timestamp])
    }

    static func ack(streamIndex: String, message: String, status: Int) -> String {
        encode(opcode: "ack", args: [streamIndex, message, String(status)])
    }

    static func argv(streamIndex: Int, mimeType: String, name: String) -> String {
        encode(opcode: "argv", args: [String(streamIndex), mimeType, name])
    }

    static func blob(streamIndex: Int, base64Data: String) -> String {
        encode(opcode: "blob", args: [String(streamIndex), base64Data])
    }

    static func end(streamIndex: Int) -> String {
        encode(opcode: "end", args: [String(streamIndex)])
    }

    static func clipboard(streamIndex: Int, mimeType: String) -> String {
        encode(opcode: "clipboard", args: [String(streamIndex), mimeType])
    }

    // File transfer: client-initiated upload to a filesystem object
    static func put(objectIndex: Int, streamIndex: Int, mimeType: String, name: String) -> String {
        encode(opcode: "put", args: [String(objectIndex), String(streamIndex), mimeType, name])
    }

    // Request a file/directory listing from a filesystem object
    static func get(objectIndex: Int, name: String) -> String {
        encode(opcode: "get", args: [String(objectIndex), name])
    }

    static func nop() -> String {
        encode(opcode: "nop", args: [])
    }

    static func disconnect() -> String {
        encode(opcode: "disconnect", args: [])
    }
}
