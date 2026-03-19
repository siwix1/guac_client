import AppKit
import Foundation

@MainActor
final class ConnectionSession: GuacamoleTunnelDelegate {
    let connectionID: String
    let tunnel: GuacamoleTunnel
    let display: GuacamoleDisplay
    let nsView: RemoteDisplayNSView
    var onDisconnect: ((String?) -> Void)?
    var onCredentialsRequired: (([String]) -> Void)?

    // Fields the server requested
    var requiredFields: [String] = []

    // Clipboard: incoming stream from the remote VM
    private var clipboardStreams: [Int: Data] = [:]
    // Track local pasteboard change count to detect new copies
    private var lastPasteboardChangeCount: Int = 0

    init(baseURL: String, token: AuthToken, connection: GuacConnection,
         width: Int, height: Int, dpi: Int = 96) {
        self.connectionID = connection.id
        self.tunnel = GuacamoleTunnel(
            baseURL: baseURL,
            token: token.token,
            connectionID: connection.id,
            dataSource: connection.dataSource,
            width: width,
            height: height,
            dpi: dpi
        )
        self.display = GuacamoleDisplay()
        self.nsView = RemoteDisplayNSView()
    }

    func start() {
        tunnel.delegate = self
        nsView.display = display
        nsView.tunnel = tunnel

        display.onDisplayUpdate = { [weak self] in
            guard let self else { return }
            let image = self.display.getDisplayImage()
            self.nsView.updateDisplayImage(image)
        }

        display.onCursorUpdate = { [weak self] cursor in
            self?.nsView.updateCursor(cursor)
        }

        tunnel.connect()
        startClipboardSync()
    }

    func sendCredentials(_ values: [String: String]) {
        // Each parameter is sent as a separate argv stream:
        // argv -> blob (base64 of value) -> end
        for field in requiredFields {
            let streamIndex = tunnel.allocateStreamIndex()
            let value = values[field] ?? ""
            let base64Value = Data(value.utf8).base64EncodedString()

            tunnel.send(GuacProtocolEncoder.argv(streamIndex: streamIndex, mimeType: "text/plain", name: field))
            tunnel.send(GuacProtocolEncoder.blob(streamIndex: streamIndex, base64Data: base64Value))
            tunnel.send(GuacProtocolEncoder.end(streamIndex: streamIndex))
            print("Sent argv stream for '\(field)' (stream \(streamIndex))")
        }
    }

    /// Send the current macOS clipboard contents to the remote VM.
    func sendClipboardToRemote() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let streamIndex = tunnel.allocateStreamIndex()
        let base64 = Data(text.utf8).base64EncodedString()
        tunnel.send(GuacProtocolEncoder.clipboard(streamIndex: streamIndex, mimeType: "text/plain"))
        tunnel.send(GuacProtocolEncoder.blob(streamIndex: streamIndex, base64Data: base64))
        tunnel.send(GuacProtocolEncoder.end(streamIndex: streamIndex))
    }

    /// Called when the remote VM sends clipboard data to us.
    func handleRemoteClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastPasteboardChangeCount = pb.changeCount
    }

    /// Start polling the macOS pasteboard for changes and push to the remote.
    func startClipboardSync() {
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let current = NSPasteboard.general.changeCount
                if current != lastPasteboardChangeCount {
                    lastPasteboardChangeCount = current
                    sendClipboardToRemote()
                }
            }
        }
    }

    func stop() {
        tunnel.disconnect()
    }

    // MARK: - GuacamoleTunnelDelegate

    nonisolated func tunnelDidConnect() {
        print("Tunnel connected")
    }

    nonisolated func tunnelDidReceiveInstructions(_ instructions: [GuacInstruction]) {
        Task { @MainActor in
            for instruction in instructions {
                switch instruction.opcode {
                case "required":
                    print("Server requires: \(instruction.args)")
                    requiredFields = instruction.args
                    onCredentialsRequired?(instruction.args)
                case "clipboard":
                    // clipboard,STREAM_INDEX,MIMETYPE
                    if let streamIndex = Int(instruction.args.first ?? "") {
                        clipboardStreams[streamIndex] = Data()
                        tunnel.send(GuacProtocolEncoder.ack(
                            streamIndex: String(streamIndex), message: "OK", status: 0))
                    }
                case "blob":
                    if let streamIndex = Int(instruction.args.first ?? ""),
                       clipboardStreams[streamIndex] != nil,
                       instruction.args.count >= 2,
                       let decoded = Data(base64Encoded: instruction.args[1]) {
                        clipboardStreams[streamIndex]!.append(decoded)
                        tunnel.send(GuacProtocolEncoder.ack(
                            streamIndex: String(streamIndex), message: "OK", status: 0))
                    } else {
                        display.handleInstruction(instruction, tunnel: tunnel)
                    }
                case "end":
                    if let streamIndex = Int(instruction.args.first ?? ""),
                       let data = clipboardStreams.removeValue(forKey: streamIndex),
                       let text = String(data: data, encoding: .utf8) {
                        handleRemoteClipboard(text)
                    } else {
                        display.handleInstruction(instruction, tunnel: tunnel)
                    }
                default:
                    display.handleInstruction(instruction, tunnel: tunnel)
                }
            }
        }
    }

    nonisolated func tunnelDidDisconnect(error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            onDisconnect?(message)
        }
    }
}
