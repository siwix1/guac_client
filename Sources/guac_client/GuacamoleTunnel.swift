import Foundation

protocol GuacamoleTunnelDelegate: AnyObject, Sendable {
    nonisolated func tunnelDidReceiveInstructions(_ instructions: [GuacInstruction])
    nonisolated func tunnelDidConnect()
    nonisolated func tunnelDidDisconnect(error: Error?)
}

final class GuacamoleTunnel: @unchecked Sendable {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    /// The tunnel needs its own session rather than `URLSession.shared`:
    /// the shared session ignores custom delegates, so a trust challenge on
    /// the WebSocket would never reach our handler and the connection would
    /// fail even after the user approved the certificate for the REST API.
    private let session: URLSession = URLSession(
        configuration: .default,
        delegate: GuacURLSessionDelegate(),
        delegateQueue: nil
    )
    private let parser = Mutex(GuacProtocolParser())
    private var nextStreamIndex = 0
    /// Set once the socket has failed or been closed, so a burst of queued
    /// sends can't each log the same error against a dead task.
    private let closed = Mutex(false)
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
        let wsTask = session.webSocketTask(with: url, protocols: ["guacamole"])
        self.task = wsTask
        wsTask.resume()
        print("WebSocket task resumed")
        delegate?.tunnelDidConnect()
        receiveLoop()
        startKeepAlive()
    }

    func send(_ text: String) {
        if closed.withLock({ $0 }) { return }
        task?.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            // First failure wins: tear the tunnel down and report once rather
            // than logging an identical error for every queued send.
            self.fail(with: error)
        }
    }

    func disconnect() {
        let alreadyClosed = closed.withLock { wasClosed -> Bool in
            let previous = wasClosed
            wasClosed = true
            return previous
        }
        guard !alreadyClosed else { return }

        // Send before marking closed above would be racy; emit directly.
        task?.send(.string(GuacProtocolEncoder.disconnect())) { _ in }
        task?.cancel(with: .normalClosure, reason: nil)
        delegate?.tunnelDidDisconnect(error: nil)
    }

    /// Mark the tunnel dead and notify the delegate exactly once.
    private func fail(with error: Error) {
        let alreadyClosed = closed.withLock { wasClosed -> Bool in
            let previous = wasClosed
            wasClosed = true
            return previous
        }
        guard !alreadyClosed else { return }

        print("WebSocket failed: \(error)")
        task?.cancel(with: .abnormalClosure, reason: nil)
        delegate?.tunnelDidDisconnect(error: error)
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
                self.fail(with: error)
            }
        }
    }

    private func startKeepAlive() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !self.closed.withLock({ $0 }) else { return }
                self.send(GuacProtocolEncoder.nop())
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
