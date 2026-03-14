import Carbon.HIToolbox

// Maps macOS key codes and characters to X11 keysyms used by the Guacamole protocol
enum KeySymMapping {
    // Map common characters to X11 keysyms
    static func keysym(for character: Character) -> Int? {
        if let ascii = character.asciiValue {
            // ASCII characters map directly in X11
            return Int(ascii)
        }

        // Special characters
        switch character {
        case "\r", "\n": return 0xFF0D // Return
        case "\t": return 0xFF09 // Tab
        case "\u{1B}": return 0xFF1B // Escape
        case "\u{7F}": return 0xFF08 // Backspace (DEL -> BackSpace)
        default: break
        }

        // Unicode: keysym = 0x01000000 + unicode code point
        if let scalar = character.unicodeScalars.first {
            return 0x01000000 + Int(scalar.value)
        }

        return nil
    }

    // Map macOS virtual key codes to X11 keysyms for non-character keys
    static func keysym(forKeyCode keyCode: UInt16) -> Int? {
        switch Int(keyCode) {
        case kVK_Return: return 0xFF0D
        case kVK_Tab: return 0xFF09
        case kVK_Space: return 0x0020
        case kVK_Delete: return 0xFF08 // Backspace
        case kVK_ForwardDelete: return 0xFFFF
        case kVK_Escape: return 0xFF1B
        case kVK_LeftArrow: return 0xFF51
        case kVK_RightArrow: return 0xFF53
        case kVK_UpArrow: return 0xFF52
        case kVK_DownArrow: return 0xFF54
        case kVK_Home: return 0xFF50
        case kVK_End: return 0xFF57
        case kVK_PageUp: return 0xFF55
        case kVK_PageDown: return 0xFF56
        case kVK_Shift: return 0xFFE1
        case kVK_RightShift: return 0xFFE2
        case kVK_Control: return 0xFFE3
        case kVK_RightControl: return 0xFFE4
        case kVK_Option: return 0xFFE9 // Alt
        case kVK_RightOption: return 0xFFEA
        case kVK_Command: return 0xFFEB // Super/Meta
        case kVK_RightCommand: return 0xFFEC
        case kVK_CapsLock: return 0xFFE5
        case kVK_F1: return 0xFFBE
        case kVK_F2: return 0xFFBF
        case kVK_F3: return 0xFFC0
        case kVK_F4: return 0xFFC1
        case kVK_F5: return 0xFFC2
        case kVK_F6: return 0xFFC3
        case kVK_F7: return 0xFFC4
        case kVK_F8: return 0xFFC5
        case kVK_F9: return 0xFFC6
        case kVK_F10: return 0xFFC7
        case kVK_F11: return 0xFFC8
        case kVK_F12: return 0xFFC9
        case kVK_VolumeUp: return 0x1008FF13
        case kVK_VolumeDown: return 0x1008FF11
        case kVK_Mute: return 0x1008FF12
        default: return nil
        }
    }

    // Check if a key code represents a modifier or special key (no character)
    static func isNonCharacterKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift,
             kVK_Control, kVK_RightControl,
             kVK_Option, kVK_RightOption,
             kVK_Command, kVK_RightCommand,
             kVK_CapsLock,
             kVK_F1, kVK_F2, kVK_F3, kVK_F4,
             kVK_F5, kVK_F6, kVK_F7, kVK_F8,
             kVK_F9, kVK_F10, kVK_F11, kVK_F12,
             kVK_LeftArrow, kVK_RightArrow,
             kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End,
             kVK_PageUp, kVK_PageDown,
             kVK_ForwardDelete, kVK_Escape:
            return true
        default:
            return false
        }
    }
}
