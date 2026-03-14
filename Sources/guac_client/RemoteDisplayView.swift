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

    override func keyDown(with event: NSEvent) {
        if KeySymMapping.isNonCharacterKey(event.keyCode) {
            if let keysym = KeySymMapping.keysym(forKeyCode: event.keyCode) {
                tunnel?.send(GuacProtocolEncoder.key(keysym: keysym, pressed: true))
            }
        } else if let chars = event.characters {
            for char in chars {
                if let keysym = KeySymMapping.keysym(for: char) {
                    tunnel?.send(GuacProtocolEncoder.key(keysym: keysym, pressed: true))
                }
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if KeySymMapping.isNonCharacterKey(event.keyCode) {
            if let keysym = KeySymMapping.keysym(forKeyCode: event.keyCode) {
                tunnel?.send(GuacProtocolEncoder.key(keysym: keysym, pressed: false))
            }
        } else if let chars = event.characters {
            for char in chars {
                if let keysym = KeySymMapping.keysym(for: char) {
                    tunnel?.send(GuacProtocolEncoder.key(keysym: keysym, pressed: false))
                }
            }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Handle modifier key changes
        let modifiers: [(NSEvent.ModifierFlags, UInt16, UInt16)] = [
            (.shift, UInt16(kVK_Shift), UInt16(kVK_RightShift)),
            (.control, UInt16(kVK_Control), UInt16(kVK_RightControl)),
            (.option, UInt16(kVK_Option), UInt16(kVK_RightOption)),
            (.command, UInt16(kVK_Command), UInt16(kVK_RightCommand)),
        ]

        for (flag, leftCode, _) in modifiers {
            if let keysym = KeySymMapping.keysym(forKeyCode: leftCode) {
                let pressed = event.modifierFlags.contains(flag)
                tunnel?.send(GuacProtocolEncoder.key(keysym: keysym, pressed: pressed))
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
