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
        updateTrackingArea()
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
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
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
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if let cursor = remoteCursor {
            addCursorRect(bounds, cursor: cursor)
        }
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

        ctx.interpolationQuality = .high
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

    private func sendKey(event: NSEvent, pressed: Bool) {
        // Handle non-character keys (arrows, function keys, delete, return, etc.)
        if KeySymMapping.isNonCharacterKey(event.keyCode) {
            if let keysym = KeySymMapping.keysym(forKeyCode: event.keyCode) {
                tunnel?.send(GuacProtocolEncoder.key(keysym: keysym, pressed: pressed))
            }
            return
        }

        // For character keys, use charactersIgnoringModifiers to get the base key
        // This ensures Shift+Enter, Cmd+C etc. resolve correctly
        let chars: String?
        if event.modifierFlags.contains(.command) {
            // When Cmd is held, characters may be empty — use the unmodified key
            chars = event.charactersIgnoringModifiers
        } else {
            chars = event.characters ?? event.charactersIgnoringModifiers
        }

        if let chars {
            for char in chars {
                if let keysym = KeySymMapping.keysym(for: char) {
                    tunnel?.send(GuacProtocolEncoder.key(keysym: keysym, pressed: pressed))
                }
            }
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
        // Handle modifier key changes
        // Map Cmd -> Ctrl on the remote side so Cmd+C/V/X/A work as expected on Windows
        let modifiers: [(NSEvent.ModifierFlags, Int)] = [
            (.shift,   0xFFE1), // Shift_L
            (.control, 0xFFE3), // Control_L
            (.option,  0xFFE9), // Alt_L
            (.command, commandIsCtrl ? 0xFFE3 : 0xFFEB), // Cmd -> Ctrl_L (or Super_L)
        ]

        for (flag, keysym) in modifiers {
            let pressed = event.modifierFlags.contains(flag)
            let wasActive = activeModifiers.contains(keysym)

            if pressed && !wasActive {
                activeModifiers.insert(keysym)
                tunnel?.send(GuacProtocolEncoder.key(keysym: keysym, pressed: true))
            } else if !pressed && wasActive {
                activeModifiers.remove(keysym)
                tunnel?.send(GuacProtocolEncoder.key(keysym: keysym, pressed: false))
            }
        }
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
