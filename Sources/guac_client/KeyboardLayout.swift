import Carbon.HIToolbox
import AppKit

/// Resolves macOS virtual key codes to the Unicode characters the active
/// keyboard layout would actually produce for a given modifier combination.
///
/// We don't trust `NSEvent.charactersIgnoringModifiers`: on macOS it returns
/// the *unshifted* base character even when Shift is held (so Shift+`-`
/// returns `-`, not `_`). When we forward that to a Windows/X11 host along
/// with Shift, the host sees Shift+`-` and produces `-`, not `_`. Asking the
/// layout directly for the shifted character avoids the problem.
enum KeyboardLayout {
    /// Translate (keyCode, modifierFlags) → Unicode string using the user's
    /// current keyboard layout. Returns nil for keys that don't produce text
    /// (arrows, F-keys, etc.).
    static func string(forKeyCode keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue()
        let layout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)

        var modifierKeyState: UInt32 = 0
        if modifiers.contains(.shift)   { modifierKeyState |= UInt32(shiftKey >> 8) }
        if modifiers.contains(.option)  { modifierKeyState |= UInt32(optionKey >> 8) }
        if modifiers.contains(.control) { modifierKeyState |= UInt32(controlKey >> 8) }
        if modifiers.contains(.capsLock){ modifierKeyState |= UInt32(alphaLock >> 8) }

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0

        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            modifierKeyState,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
