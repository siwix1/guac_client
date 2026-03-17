import Foundation

protocol GuacamoleTunnelDelegate: AnyObject, Sendable {
    nonisolated func tunnelDidReceiveInstructions(_ instructions: [GuacInstruction])
    nonisolated func tunnelDidConnect()
    nonisolated func tunnelDidDisconnect(error: Error?)
}

final class GuacamoleTunnel: @unchecked Sendable {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private let parser = Mutex(GuacProtocolParser())
    private var nextStreamIndex = 0
    weak var delegate: GuacamoleTunnelDelegate?

    func allocateStreamIndex() -> Int {
        let index = nextStreamIndex
        nextStreamIndex += 1
        return index
    }

    init(baseURL: String, token: String, connectionID: String, dataSource: String,
         width: Int, height: Int, dpi: Int) {
        let query = [
            "token=\(token)",
            "GUAC_ID=\(connectionID)",
            "GUAC_TYPE=c",
            "GUAC_DATA_SOURCE=\(dataSource)",
            "GUAC_WIDTH=\(width)",
            "GUAC_HEIGHT=\(height)",
            "GUAC_DPI=\(dpi)",
            "GUAC_IMAGE=image/png",
            "GUAC_IMAGE=image/webp",
            "GUAC_AUDIO=audio/L16",
            "GUAC_TIMEZONE=\(TimeZone.current.identifier)",
        ].joined(separator: "&")
        let wsBase = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        self.url = URL(string: "\(wsBase)/websocket-tunnel?\(query)")!
    }

    func connect() {
        print("WebSocket connecting to: \(url)")
        let wsTask = URLSession.shared.webSocketTask(with: url, protocols: ["guacamole"])
        self.task = wsTask
        wsTask.resume()
        print("WebSocket task resumed")
        delegate?.tunnelDidConnect()
        receiveLoop()
        startKeepAlive()
    }

    func send(_ text: String) {
        task?.send(.string(text)) { error in
            if let error {
                print("WebSocket send error: \(error)")
            }
        }
    }

    func disconnect() {
        send(GuacProtocolEncoder.disconnect())
        task?.cancel(with: .normalClosure, reason: nil)
        delegate?.tunnelDidDisconnect(error: nil)
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    let instructions = self.parser.withLock { parser in
                        parser.receive(text)
                    }
                    if !instructions.isEmpty {
                        self.delegate?.tunnelDidReceiveInstructions(instructions)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        let instructions = self.parser.withLock { parser in
                            parser.receive(text)
                        }
                        if !instructions.isEmpty {
                            self.delegate?.tunnelDidReceiveInstructions(instructions)
                        }
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()

            case .failure(let error):
                print("WebSocket error: \(error)")
                self.delegate?.tunnelDidDisconnect(error: error)
            }
        }
    }

    private func startKeepAlive() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                send(GuacProtocolEncoder.nop())
            }
        }
    }
}

// Simple mutex for thread-safe parser access
final class Mutex<Value: Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
