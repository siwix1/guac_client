import AppKit
import Foundation

@MainActor
final class ConnectionSession: GuacamoleTunnelDelegate {
    let tunnel: GuacamoleTunnel
    let display: GuacamoleDisplay
    let nsView: RemoteDisplayNSView
    var onDisconnect: ((String?) -> Void)?
    var onCredentialsRequired: (([String]) -> Void)?

    // Fields the server requested
    var requiredFields: [String] = []

    init(baseURL: String, token: AuthToken, connection: GuacConnection,
         width: Int, height: Int) {
        self.tunnel = GuacamoleTunnel(
            baseURL: baseURL,
            token: token.token,
            connectionID: connection.id,
            dataSource: connection.dataSource,
            width: width,
            height: height,
            dpi: 96
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

        tunnel.connect()
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
                if instruction.opcode == "required" {
                    print("Server requires: \(instruction.args)")
                    requiredFields = instruction.args
                    onCredentialsRequired?(instruction.args)
                } else {
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
