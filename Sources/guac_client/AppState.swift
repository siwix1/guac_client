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

        // Build the window and put it into full screen FIRST, then connect the
        // remote at the resulting resolution. RDP negotiates resolution at
        // connect time and the guacd RDP backend ignores runtime `size`
        // instructions unless the connection enables dynamic resize — so
        // whatever size we connect at is what sticks. Entering full screen
        // before connecting means the desktop is negotiated at the full-screen
        // resolution and fills the display with no letterbox.
        makeConnectionWindow(connection: connection) { [weak self] window in
            guard let self else { return }
            self.connectSession(connection: connection, baseURL: baseURL, token: token, in: window)
        }
    }

    /// Connect a session sized to the (now settled) window and mount its view.
    private func connectSession(connection: GuacConnection, baseURL: String, token: AuthToken, in window: NSWindow) {
        // Request the window's point size at a normal 96 DPI. Testing showed
        // guacd's RDP backend treats a high dpi (e.g. 192) as a scale factor and
        // *halves* the pixel resolution — 2560×1279 @192 came back as 1280×639,
        // which is why the desktop looked low-res. So we keep DPI at 96 and ask
        // for the full point resolution, which gives a crisp, readable desktop
        // that fills the window.
        let contentSize = window.contentView?.bounds.size ?? NSSize(width: 1280, height: 800)
        let pixelWidth = Int(contentSize.width.rounded())
        let pixelHeight = Int(contentSize.height.rounded())
        let dpi = 96

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

        // Attach the session's remote view to the already-visible window.
        installConnectionView(session: session, connection: connection, in: window)

        session.start()
        activeSessions[connection.id] = session
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

    /// Create, show, and put the connection window into full screen with an
    /// empty content view, then call `onReady` once the window has settled at
    /// its final size — so the caller can measure it and connect the remote at
    /// that resolution. `onReady` fires on the main actor.
    private func makeConnectionWindow(connection: GuacConnection, onReady: @escaping (NSWindow) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = connection.name
        window.setFrameAutosaveName("connection_\(connection.id)")
        window.center()
        window.collectionBehavior.insert(.fullScreenPrimary)

        let controller = NSWindowController(window: window)
        windowControllers[connection.id] = controller

        // Fire onReady exactly once, whether we get there via the full-screen
        // transition or the fallback timer.
        var didFire = false
        let ready: (NSWindow) -> Void = { win in
            guard !didFire else { return }
            didFire = true
            win.layoutIfNeeded()
            onReady(win)
        }

        let delegate = ConnectionWindowDelegate(
            onClose: { [weak self] in self?.closeSession(connectionID: connection.id) },
            onEnterFullScreen: { [weak window] in
                guard let window else { return }
                ready(window)
            }
        )
        window.delegate = delegate
        // Retain the delegate
        objc_setAssociatedObject(window, "windowDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        // Enter full screen; we connect once the transition completes (above).
        window.toggleFullScreen(nil)

        // Fallback: if the full-screen transition never reports back (e.g. it's
        // blocked or already full screen), connect anyway after a short delay so
        // we never hang without a session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak window] in
            guard let window else { return }
            ready(window)
        }
    }

    /// Mount the session's remote-display SwiftUI view into an existing window.
    private func installConnectionView(session: ConnectionSession, connection: GuacConnection, in window: NSWindow) {
        let connectionView = ConnectionView(
            session: session,
            connectionID: session.connectionID,
            defaultUsername: username
        ) { [weak self] in
            self?.closeSession(connectionID: connection.id)
        }
        window.contentView = NSHostingView(rootView: connectionView)
    }
}

class ConnectionWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    let onEnterFullScreen: (() -> Void)?

    init(onClose: @escaping () -> Void, onEnterFullScreen: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onEnterFullScreen = onEnterFullScreen
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            onClose()
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        Task { @MainActor in
            onEnterFullScreen?()
        }
    }
}
