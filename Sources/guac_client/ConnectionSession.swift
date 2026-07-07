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

    /// DPI the connection was established with, reused when the view resizes so
    /// the server keeps rendering at the same pixel density.
    private let dpi: Int
    /// Last remote size we requested, so we don't spam identical `size`
    /// instructions on every sub-pixel layout pass.
    private var lastRequestedSize: (width: Int, height: Int)?

    // Fields the server requested
    var requiredFields: [String] = []

    // Clipboard: incoming stream from the remote VM. Tracks the mime type the
    // server advertised so we know whether to forward the bytes as text or an
    // image to NSPasteboard.
    private var clipboardStreams: [Int: ClipboardStream] = [:]
    // Track local pasteboard change count to detect new copies
    private var lastPasteboardChangeCount: Int = 0

    private struct ClipboardStream {
        let mimeType: String
        var data: Data
    }

    // File transfer: incoming file downloads from the remote VM
    private var fileStreams: [Int: FileDownload] = [:]
    // Filesystem objects announced by the server (objectIndex → name)
    private(set) var filesystemObjects: [Int: String] = [:]
    // Upload progress tracking
    private var activeUploads: [Int: FileUpload] = [:]

    private struct FileDownload {
        let filename: String
        let mimeType: String
        var data: Data
    }

    private struct FileUpload {
        let filename: String
        let totalSize: Int
        var bytesSent: Int
    }

    init(baseURL: String, token: AuthToken, connection: GuacConnection,
         width: Int, height: Int, dpi: Int = 96) {
        self.connectionID = connection.id
        self.dpi = dpi
        self.lastRequestedSize = (width, height)
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

        display.onCursorUpdate = { [weak self] in
            self?.nsView.cursorDidChange()
        }

        nsView.onSizeChange = { [weak self] size in
            self?.requestResize(width: size.width, height: size.height)
        }

        tunnel.connect()
        startClipboardSync()
    }

    /// Best-effort runtime resize: ask the server to re-render at `width`×
    /// `height` backing pixels so the desktop tracks the window. Note the guacd
    /// RDP backend only honors this when the connection enables dynamic resize
    /// (resize-method=display-update); otherwise the resolution set at connect
    /// time is authoritative and this is a no-op on the server side.
    func requestResize(width: CGFloat, height: CGFloat) {
        let w = Int(width.rounded())
        let h = Int(height.rounded())

        guard w > 0, h > 0 else { return }
        if let last = lastRequestedSize, last.width == w, last.height == h {
            return
        }
        lastRequestedSize = (w, h)
        tunnel.send(GuacProtocolEncoder.size(width: w, height: h, dpi: dpi))
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

    /// Send the current macOS clipboard contents to the remote VM. Prefers
    /// images when present (screenshots, copied graphics) and falls back to
    /// text.
    func sendClipboardToRemote() {
        let pb = NSPasteboard.general

        if let pngData = pb.data(forType: .png) {
            sendClipboardBlob(mimeType: "image/png", data: pngData)
            return
        }
        // Some apps put TIFF on the pasteboard for screenshots. Convert to PNG
        // before sending — Windows clipboard receivers are far more reliable
        // with PNG than TIFF.
        if let tiffData = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiffData),
           let pngData = rep.representation(using: .png, properties: [:]) {
            sendClipboardBlob(mimeType: "image/png", data: pngData)
            return
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            sendClipboardBlob(mimeType: "text/plain", data: Data(text.utf8))
            return
        }
    }

    /// Send a clipboard payload of arbitrary mime type to the remote, chunked
    /// to stay under the Guacamole protocol's blob size limit (~6KB base64).
    private func sendClipboardBlob(mimeType: String, data: Data) {
        let streamIndex = tunnel.allocateStreamIndex()
        tunnel.send(GuacProtocolEncoder.clipboard(streamIndex: streamIndex, mimeType: mimeType))

        let chunkSize = 4096
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let base64 = data[offset..<end].base64EncodedString()
            tunnel.send(GuacProtocolEncoder.blob(streamIndex: streamIndex, base64Data: base64))
            offset = end
        }

        tunnel.send(GuacProtocolEncoder.end(streamIndex: streamIndex))
    }

    /// Called when the remote VM sends clipboard data to us.
    private func handleRemoteClipboard(mimeType: String, data: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()

        if mimeType.hasPrefix("image/") {
            // Forward as PNG for broadest app compatibility on macOS. If the
            // bytes aren't already PNG, round-trip via NSImage to re-encode.
            if mimeType == "image/png" {
                pb.setData(data, forType: .png)
            } else if let image = NSImage(data: data),
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) {
                pb.setData(png, forType: .png)
            }
        } else if let text = String(data: data, encoding: .utf8) {
            pb.setString(text, forType: .string)
        }

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

    // MARK: - File transfer

    /// Upload a local file to the remote VM's filesystem.
    func uploadFile(url: URL) {
        guard let objectIndex = filesystemObjects.keys.first else {
            print("No filesystem available for upload")
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            print("Failed to read file: \(url.path)")
            return
        }

        let streamIndex = tunnel.allocateStreamIndex()
        let filename = url.lastPathComponent
        let mimeType = mimeTypeForExtension(url.pathExtension)

        tunnel.send(GuacProtocolEncoder.put(
            objectIndex: objectIndex,
            streamIndex: streamIndex,
            mimeType: mimeType,
            name: filename
        ))

        activeUploads[streamIndex] = FileUpload(
            filename: filename, totalSize: data.count, bytesSent: 0)

        // Send data in 6KB chunks (Guacamole blob limit is ~6KB base64 ≈ 4KB raw)
        let chunkSize = 4096
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]
            let base64 = chunk.base64EncodedString()
            tunnel.send(GuacProtocolEncoder.blob(streamIndex: streamIndex, base64Data: base64))
            offset = end
        }

        tunnel.send(GuacProtocolEncoder.end(streamIndex: streamIndex))
        print("Upload started: \(filename) (\(data.count) bytes)")
    }

    /// Save a downloaded file to disk via NSSavePanel.
    private func saveDownloadedFile(_ download: FileDownload) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = download.filename
        panel.canCreateDirectories = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? download.data.write(to: url)
                print("Saved: \(url.path)")
            }
        }
    }

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "txt": return "text/plain"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "html", "htm": return "text/html"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
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

                case "filesystem":
                    // filesystem,OBJECT_INDEX,NAME
                    if instruction.args.count >= 2,
                       let objectIndex = Int(instruction.args[0]) {
                        let name = instruction.args[1]
                        filesystemObjects[objectIndex] = name
                        print("Filesystem available: \(name) (object \(objectIndex))")
                    }

                case "file":
                    // file,STREAM_INDEX,MIMETYPE,FILENAME
                    if instruction.args.count >= 3,
                       let streamIndex = Int(instruction.args[0]) {
                        let mimeType = instruction.args[1]
                        let filename = instruction.args[2]
                        fileStreams[streamIndex] = FileDownload(
                            filename: filename, mimeType: mimeType, data: Data())
                        tunnel.send(GuacProtocolEncoder.ack(
                            streamIndex: String(streamIndex), message: "OK", status: 0))
                        print("File download starting: \(filename)")
                    }

                case "ack":
                    // ack for our upload streams — just track progress
                    if let streamIndex = Int(instruction.args.first ?? ""),
                       activeUploads[streamIndex] != nil {
                        // Upload ack received, nothing to do
                    } else {
                        display.handleInstruction(instruction, tunnel: tunnel)
                    }

                case "clipboard":
                    // clipboard,STREAM_INDEX,MIMETYPE
                    if instruction.args.count >= 2,
                       let streamIndex = Int(instruction.args[0]) {
                        let mimeType = instruction.args[1]
                        clipboardStreams[streamIndex] = ClipboardStream(mimeType: mimeType, data: Data())
                        tunnel.send(GuacProtocolEncoder.ack(
                            streamIndex: String(streamIndex), message: "OK", status: 0))
                    }

                case "blob":
                    guard let streamIndex = Int(instruction.args.first ?? ""),
                          instruction.args.count >= 2,
                          let decoded = Data(base64Encoded: instruction.args[1]) else {
                        display.handleInstruction(instruction, tunnel: tunnel)
                        break
                    }

                    if clipboardStreams[streamIndex] != nil {
                        clipboardStreams[streamIndex]!.data.append(decoded)
                        tunnel.send(GuacProtocolEncoder.ack(
                            streamIndex: String(streamIndex), message: "OK", status: 0))
                    } else if fileStreams[streamIndex] != nil {
                        fileStreams[streamIndex]!.data.append(decoded)
                        tunnel.send(GuacProtocolEncoder.ack(
                            streamIndex: String(streamIndex), message: "OK", status: 0))
                    } else {
                        display.handleInstruction(instruction, tunnel: tunnel)
                    }

                case "end":
                    guard let streamIndex = Int(instruction.args.first ?? "") else {
                        display.handleInstruction(instruction, tunnel: tunnel)
                        break
                    }

                    if let stream = clipboardStreams.removeValue(forKey: streamIndex) {
                        handleRemoteClipboard(mimeType: stream.mimeType, data: stream.data)
                    } else if let download = fileStreams.removeValue(forKey: streamIndex) {
                        print("File download complete: \(download.filename) (\(download.data.count) bytes)")
                        saveDownloadedFile(download)
                    } else if activeUploads.removeValue(forKey: streamIndex) != nil {
                        print("Upload complete")
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
