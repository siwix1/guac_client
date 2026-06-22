import AppKit
import Carbon.HIToolbox
import SwiftUI

// NSView that renders the Guacamole display and captures input
class RemoteDisplayNSView: NSView {
    var display: GuacamoleDisplay?
    var tunnel: GuacamoleTunnel?

    private var buttonMask: Int = 0
    private var displayImage: CGImage?
    private var trackingArea: NSTrackingArea?
    private var remoteCursor: NSCursor?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        // Ensure Retina-sharp rendering by matching the backing scale
        if let scaleFactor = window?.backingScaleFactor {
            layer?.contentsScale = scaleFactor
        }
        updateTrackingArea()
    }

    override func resignFirstResponder() -> Bool {
        releaseAllModifiers()
        return super.resignFirstResponder()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func updateDisplayImage(_ image: CGImage?) {
        displayImage = image
        needsDisplay = true
    }

    func updateCursor(_ cursor: NSCursor) {
        remoteCursor = cursor
        // Push the cursor immediately if the mouse is inside our view
        if let window = self.window,
           NSMouseInRect(window.mouseLocationOutsideOfEventStream, bounds, isFlipped) {
            cursor.set()
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        discardCursorRects()
        if let cursor = remoteCursor {
            addCursorRect(bounds, cursor: cursor)
        } else {
            // Fallback: hide system cursor by using a transparent one
            addCursorRect(bounds, cursor: .arrow)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        // Override to prevent AppKit from resetting to the default arrow
        remoteCursor?.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Black background
        ctx.setFillColor(CGColor.black)
        ctx.fill(bounds)

        guard let image = displayImage else { return }

        // Scale to fit, maintaining aspect ratio
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: (bounds.width - scaledSize.width) / 2,
            y: (bounds.height - scaledSize.height) / 2
        )

        // Use no interpolation at 1:1 for pixel-perfect sharpness, high quality when scaling
        ctx.interpolationQuality = abs(scale - 1.0) < 0.01 ? .none : .high
        // Flip the image vertically around its center
        ctx.saveGState()
        let centerY = origin.y + scaledSize.height / 2
        ctx.translateBy(x: 0, y: centerY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -centerY)
        ctx.draw(image, in: CGRect(origin: origin, size: scaledSize))
        ctx.restoreGState()
    }

    // MARK: - Coordinate mapping

    private func remotePoint(from event: NSEvent) -> (x: Int, y: Int)? {
        guard let image = displayImage else { return nil }
        let local = convert(event.locationInWindow, from: nil)

        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: (bounds.width - scaledSize.width) / 2,
            y: (bounds.height - scaledSize.height) / 2
        )

        let remoteX = (local.x - origin.x) / scale
        let remoteY = (local.y - origin.y) / scale // isFlipped=true, so Y is already top-down

        guard remoteX >= 0 && remoteX < imageSize.width &&
              remoteY >= 0 && remoteY < imageSize.height else { return nil }

        return (Int(remoteX), Int(remoteY))
    }

    // MARK: - Mouse events

    private func sendMouse(_ event: NSEvent) {
        guard let point = remotePoint(from: event) else { return }
        tunnel?.send(GuacProtocolEncoder.mouse(x: point.x, y: point.y, buttonMask: buttonMask))
    }

    override func mouseDown(with event: NSEvent) {
        buttonMask |= 1
        sendMouse(event)
    }

    override func mouseUp(with event: NSEvent) {
        buttonMask &= ~1
        sendMouse(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        buttonMask |= 4
        sendMouse(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttonMask &= ~4
        sendMouse(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        buttonMask |= 2
        sendMouse(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        buttonMask &= ~2
        sendMouse(event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMouse(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMouse(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMouse(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMouse(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = remotePoint(from: event) else { return }

        if event.deltaY > 0 {
            // Scroll up
            tunnel?.send(GuacProtocolEncoder.mouse(x: point.x, y: point.y, buttonMask: buttonMask | 8))
            tunnel?.send(GuacProtocolEncoder.mouse(x: point.x, y: point.y, buttonMask: buttonMask))
        } else if event.deltaY < 0 {
            // Scroll down
            tunnel?.send(GuacProtocolEncoder.mouse(x: point.x, y: point.y, buttonMask: buttonMask | 16))
            tunnel?.send(GuacProtocolEncoder.mouse(x: point.x, y: point.y, buttonMask: buttonMask))
        }
    }

    // MARK: - Keyboard events

    // Track which modifier keysyms are currently pressed
    private var activeModifiers: Set<Int> = []

    /// Translate Cmd+key to Ctrl+key for the remote Windows side
    private var commandIsCtrl: Bool { true }

    /// Modifier flags we track.  Each entry maps a macOS flag to a unique
    /// internal key and its remote keysym.  We use the internal key (not the
    /// keysym) for `activeModifiers` so that Command and Control don't collide
    /// when both map to the same remote keysym (Ctrl_L).
    private struct ModifierEntry {
        let flag: NSEvent.ModifierFlags
        let key: String      // unique internal identifier
        let keysym: Int       // remote keysym to send
    }

    private var modifierMap: [ModifierEntry] {
        [
            ModifierEntry(flag: .shift,   key: "shift",   keysym: 0xFFE1), // Shift_L
            ModifierEntry(flag: .control, key: "control", keysym: 0xFFE3), // Control_L
            ModifierEntry(flag: .option,  key: "option",  keysym: 0xFFE9), // Alt_L
            ModifierEntry(flag: .command, key: "command",
                          keysym: commandIsCtrl ? 0xFFE3 : 0xFFEB),        // Cmd -> Ctrl_L (or Super_L)
        ]
    }

    // Track active modifiers by their unique key (not keysym) to avoid
    // Command/Control collision when both map to 0xFFE3.
    private var activeModifierKeys: Set<String> = []

    /// Sync modifier state from flags.  Updates tracking and returns
    /// protocol instructions for any changes.
    private func syncModifiers(from flags: NSEvent.ModifierFlags) -> String {
        var instructions = ""
        for entry in modifierMap {
            let pressed = flags.contains(entry.flag)
            let wasActive = activeModifierKeys.contains(entry.key)
            if pressed && !wasActive {
                activeModifierKeys.insert(entry.key)
                instructions += GuacProtocolEncoder.key(keysym: entry.keysym, pressed: true)
            } else if !pressed && wasActive {
                activeModifierKeys.remove(entry.key)
                instructions += GuacProtocolEncoder.key(keysym: entry.keysym, pressed: false)
            }
        }
        return instructions
    }

    /// Build modifier press instructions for every modifier currently held,
    /// regardless of whether we already sent them.  This ensures the server
    /// sees the modifier before the character even if a previous `flagsChanged`
    /// WebSocket message is still in-flight.
    private func ensureModifiers(from flags: NSEvent.ModifierFlags) -> String {
        var instructions = ""
        for entry in modifierMap {
            if flags.contains(entry.flag) {
                activeModifierKeys.insert(entry.key)
                instructions += GuacProtocolEncoder.key(keysym: entry.keysym, pressed: true)
            }
        }
        return instructions
    }

    /// Release all held modifiers — called when the view loses focus.
    private func releaseAllModifiers() {
        var batch = ""
        for entry in modifierMap {
            if activeModifierKeys.contains(entry.key) {
                batch += GuacProtocolEncoder.key(keysym: entry.keysym, pressed: false)
            }
        }
        activeModifierKeys.removeAll()

        // Release any character keys still held on the remote side.
        for keysym in heldCharKeysyms.values {
            batch += GuacProtocolEncoder.key(keysym: keysym, pressed: false)
        }
        heldCharKeysyms.removeAll()

        // Also release CapsLock if held
        if activeModifiers.contains(0xFFE5) {
            activeModifiers.remove(0xFFE5)
            batch += GuacProtocolEncoder.key(keysym: 0xFFE5, pressed: false)
        }

        if !batch.isEmpty { tunnel?.send(batch) }
    }

    /// Keysyms of character keys currently held, indexed by keyCode, so we can
    /// release exactly the same keysym we pressed even if the user lets go of
    /// Shift before releasing the letter.
    private var heldCharKeysyms: [UInt16: Int] = [:]

    private func sendKey(event: NSEvent, pressed: Bool) {
        let flags = event.modifierFlags

        // Non-character keys (arrows, F-keys, return, delete, etc.): keep the
        // existing modifier-forwarding behavior — the remote needs Shift/Ctrl
        // state to interpret Shift+Arrow, Ctrl+C, and so on.
        if KeySymMapping.isNonCharacterKey(event.keyCode) {
            var batch = pressed
                ? ensureModifiers(from: flags)
                : syncModifiers(from: flags)
            if let keysym = KeySymMapping.keysym(forKeyCode: event.keyCode) {
                batch += GuacProtocolEncoder.key(keysym: keysym, pressed: pressed)
            }
            if !batch.isEmpty { tunnel?.send(batch) }
            return
        }

        // Character keys: ask the active layout what character this physical
        // key produces with the current modifier state. This makes Shift+`-`
        // resolve to `_` (keysym 0x5F) instead of Shift+`-` (which the remote
        // interprets as `-`). Same for capitals, symbols, AltGr layouts, etc.
        //
        // We also strip Shift from the modifier set we forward: the shifted
        // keysym already encodes "shifted", and sending Shift alongside causes
        // double-shifting / races on some hosts. Cmd and Ctrl are still
        // forwarded so shortcuts (Cmd+V, Ctrl+C) work.
        if pressed {
            let string = KeyboardLayout.string(forKeyCode: event.keyCode, modifiers: flags)
                ?? event.characters
                ?? ""

            // Forward Cmd/Ctrl/Option (but not Shift) so shortcuts still work.
            // Temporarily release Shift if it's held so the shifted keysym is
            // unambiguous on the remote side.
            var batch = ""
            for entry in modifierMap where entry.flag != .shift {
                if flags.contains(entry.flag) && !activeModifierKeys.contains(entry.key) {
                    activeModifierKeys.insert(entry.key)
                    batch += GuacProtocolEncoder.key(keysym: entry.keysym, pressed: true)
                }
            }
            if activeModifierKeys.contains("shift") {
                activeModifierKeys.remove("shift")
                batch += GuacProtocolEncoder.key(keysym: 0xFFE1, pressed: false)
            }

            for char in string {
                if let keysym = KeySymMapping.keysym(for: char) {
                    heldCharKeysyms[event.keyCode] = keysym
                    batch += GuacProtocolEncoder.key(keysym: keysym, pressed: true)
                }
            }
            if !batch.isEmpty { tunnel?.send(batch) }
        } else {
            // Release exactly the keysym we pressed for this keyCode. Looking
            // it up by current modifiers would be wrong: the user may have
            // released Shift before the letter, so the layout would now report
            // the lowercase form while the remote still has the uppercase one
            // held.
            var batch = ""
            if let keysym = heldCharKeysyms.removeValue(forKey: event.keyCode) {
                batch += GuacProtocolEncoder.key(keysym: keysym, pressed: false)
            }
            // Sync non-Shift modifiers in case they were released.
            batch += syncModifiers(from: flags)
            if !batch.isEmpty { tunnel?.send(batch) }
        }
    }

    // Intercept Cmd+key shortcuts before macOS Edit menu consumes them (e.g. Cmd+V paste)
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            sendKey(event: event, pressed: true)
            // Schedule key-up since we won't get a normal keyUp for key equivalents
            DispatchQueue.main.async { [weak self] in
                self?.sendKey(event: event, pressed: false)
            }
            return true // We handled it — don't let the system menu take it
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat {
            // Send release+press so the remote side sees each repeat as a distinct keystroke
            sendKey(event: event, pressed: false)
        }
        sendKey(event: event, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event: event, pressed: false)
    }

    override func flagsChanged(with event: NSEvent) {
        var batch = syncModifiers(from: event.modifierFlags)

        // CapsLock: send press when toggled on, release when toggled off.
        // The remote side treats it as a held modifier (like Shift).
        let capsNowOn = event.modifierFlags.contains(.capsLock)
        let capsWasOn = activeModifiers.contains(0xFFE5)
        if capsNowOn && !capsWasOn {
            activeModifiers.insert(0xFFE5)
            batch += GuacProtocolEncoder.key(keysym: 0xFFE5, pressed: true)
        } else if !capsNowOn && capsWasOn {
            activeModifiers.remove(0xFFE5)
            batch += GuacProtocolEncoder.key(keysym: 0xFFE5, pressed: false)
        }

        if !batch.isEmpty { tunnel?.send(batch) }
    }
}

// SwiftUI wrapper
struct RemoteDisplayView: NSViewRepresentable {
    let nsView: RemoteDisplayNSView

    func makeNSView(context: Context) -> RemoteDisplayNSView {
        return nsView
    }

    func updateNSView(_ nsView: RemoteDisplayNSView, context: Context) {}
}
