import Foundation
import SwiftUI

@MainActor
@Observable
final class AppState {
    var authState: AuthState = .needsCredentials
    var connections: [GuacConnection] = []
    var isLoading = false
    var errorMessage: String?

    /// All active connection sessions, each displayed in its own window
    var activeSessions: [String: ConnectionSession] = [:]

    // Store login credentials for RDP pass-through
    private(set) var username: String = ""
    private(set) var password: String = ""

    private var api = GuacamoleAPI(baseURL: "")
    private(set) var token: AuthToken?
    private(set) var baseURL: String = ""

    /// Window controllers for connection windows
    var windowControllers: [String: NSWindowController] = [:]

    /// Try to restore a saved session token on app launch. Returns true if successful.
    func tryRestoreSession() async {
        guard let savedToken = UserDefaults.standard.string(forKey: "savedToken"),
              let savedDataSource = UserDefaults.standard.string(forKey: "savedDataSource"),
              let savedSources = UserDefaults.standard.stringArray(forKey: "savedAvailableDataSources"),
              let savedBaseURL = UserDefaults.standard.string(forKey: "savedServerURL"),
              !savedToken.isEmpty, !savedBaseURL.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        let authToken = AuthToken(token: savedToken, dataSource: savedDataSource, availableDataSources: savedSources)
        baseURL = savedBaseURL
        api = GuacamoleAPI(baseURL: savedBaseURL)
        username = UserDefaults.standard.string(forKey: "savedUsername") ?? ""
        password = UserDefaults.standard.string(forKey: "savedPassword") ?? ""

        // Validate the token by trying to list connections
        do {
            let conns = try await api.listConnections(token: authToken)
            if !conns.isEmpty {
                token = authToken
                connections = conns
                authState = .authenticated(authToken)
                return
            }
        } catch {
            // Token expired or invalid — fall through to login screen
        }

        // Clear stale token
        UserDefaults.standard.removeObject(forKey: "savedToken")
    }

    private func saveToken(_ authToken: AuthToken) {
        UserDefaults.standard.set(authToken.token, forKey: "savedToken")
        UserDefaults.standard.set(authToken.dataSource, forKey: "savedDataSource")
        UserDefaults.standard.set(authToken.availableDataSources, forKey: "savedAvailableDataSources")
    }

    func login(serverURL: String, username: String, password: String, totpCode: String? = nil) async {
        let trimmed = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        baseURL = trimmed
        api = GuacamoleAPI(baseURL: trimmed)
        isLoading = true
        errorMessage = nil

        do {
            let result = try await api.authenticate(
                username: username,
                password: password,
                totpCode: totpCode
            )
            authState = result

            if case .authenticated(let authToken) = result {
                self.username = username
                self.password = password
                token = authToken
                saveToken(authToken)
                await loadConnections()
            } else if case .failed(let message) = result {
                errorMessage = message
            }
        } catch {
            errorMessage = error.localizedDescription
            authState = .failed(error.localizedDescription)
        }

        isLoading = false
    }

    func loadConnections() async {
        guard let token else { return }
        do {
            connections = try await api.listConnections(token: token)
        } catch {
            errorMessage = "Failed to load connections: \(error.localizedDescription)"
        }
    }

    func connect(to connection: GuacConnection) {
        guard let token else { return }

        // If already connected, bring the existing window to front
        if activeSessions[connection.id] != nil {
            if let wc = windowControllers[connection.id] {
                wc.window?.makeKeyAndOrderFront(nil)
            }
            return
        }

        // Use the actual screen resolution for sharp rendering on Retina displays
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scaleFactor = screen?.backingScaleFactor ?? 2.0
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let pixelWidth = Int(screenFrame.width * scaleFactor)
        let pixelHeight = Int(screenFrame.height * scaleFactor)
        let dpi = Int(96.0 * scaleFactor)

        let session = ConnectionSession(
            baseURL: baseURL,
            token: token,
            connection: connection,
            width: pixelWidth,
            height: pixelHeight,
            dpi: dpi
        )

        session.onDisconnect = { [weak self] error in
            if let error {
                self?.errorMessage = error
            }
            self?.closeSession(connectionID: connection.id)
        }

        session.start()
        activeSessions[connection.id] = session

        // Open a new window for this connection
        openConnectionWindow(session: session, connection: connection)
    }

    func closeSession(connectionID: String) {
        activeSessions[connectionID]?.stop()
        activeSessions.removeValue(forKey: connectionID)

        if let wc = windowControllers.removeValue(forKey: connectionID) {
            wc.window?.close()
        }
    }

    func disconnectAll() {
        for (id, session) in activeSessions {
            session.stop()
            windowControllers[id]?.window?.close()
        }
        activeSessions.removeAll()
        windowControllers.removeAll()
    }

    func logout() {
        disconnectAll()
        authState = .needsCredentials
        connections = []
        token = nil
        username = ""
        password = ""
        errorMessage = nil
        UserDefaults.standard.removeObject(forKey: "savedToken")
        UserDefaults.standard.removeObject(forKey: "savedDataSource")
        UserDefaults.standard.removeObject(forKey: "savedAvailableDataSources")
    }

    private func openConnectionWindow(session: ConnectionSession, connection: GuacConnection) {
        let connectionView = ConnectionView(
            session: session,
            connectionID: session.connectionID,
            defaultUsername: username
        ) { [weak self] in
            self?.closeSession(connectionID: connection.id)
        }

        let hostingView = NSHostingView(rootView: connectionView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = connection.name
        window.setFrameAutosaveName("connection_\(connection.id)")
        window.center()

        let controller = NSWindowController(window: window)
        windowControllers[connection.id] = controller

        // Handle window close via X button
        let delegate = ConnectionWindowDelegate { [weak self] in
            self?.closeSession(connectionID: connection.id)
        }
        window.delegate = delegate
        // Retain the delegate
        objc_setAssociatedObject(window, "windowDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        // Maximize the window
        window.zoom(nil)
    }
}

class ConnectionWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            onClose()
        }
    }
}
