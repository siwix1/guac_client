import Foundation

struct GuacInstruction: Sendable {
    let opcode: String
    let args: [String]
}

struct GuacProtocolParser: Sendable {
    private var buffer: String = ""

    mutating func receive(_ text: String) -> [GuacInstruction] {
        buffer.append(text)
        var instructions: [GuacInstruction] = []

        while let instruction = parseNext() {
            instructions.append(instruction)
        }

        return instructions
    }

    private mutating func parseNext() -> GuacInstruction? {
        var elements: [String] = []
        var position = buffer.startIndex

        while position < buffer.endIndex {
            // Read the length prefix
            guard let dotIndex = buffer[position...].firstIndex(of: ".") else {
                return nil
            }

            guard let length = Int(buffer[position..<dotIndex]) else {
                // Malformed — skip to next semicolon
                if let semi = buffer[position...].firstIndex(of: ";") {
                    buffer = String(buffer[buffer.index(after: semi)...])
                }
                return nil
            }

            let valueStart = buffer.index(after: dotIndex)
            let valueEnd = buffer.index(valueStart, offsetBy: length, limitedBy: buffer.endIndex)
            guard let valueEnd else {
                return nil // Need more data
            }

            let value = String(buffer[valueStart..<valueEnd])
            elements.append(value)

            guard valueEnd < buffer.endIndex else {
                return nil // Need more data
            }

            let separator = buffer[valueEnd]
            position = buffer.index(after: valueEnd)

            if separator == ";" {
                // Instruction complete
                buffer = String(buffer[position...])
                guard let opcode = elements.first else { return nil }
                return GuacInstruction(opcode: opcode, args: Array(elements.dropFirst()))
            } else if separator == "," {
                // More arguments follow
                continue
            } else {
                // Unexpected character — discard
                buffer = String(buffer[position...])
                return nil
            }
        }

        return nil
    }
}

enum GuacProtocolEncoder {
    static func encode(opcode: String, args: [String]) -> String {
        var parts = ["\(opcode.count).\(opcode)"]
        for arg in args {
            parts.append("\(arg.count).\(arg)")
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

    static func nop() -> String {
        encode(opcode: "nop", args: [])
    }

    static func disconnect() -> String {
        encode(opcode: "disconnect", args: [])
    }
}
