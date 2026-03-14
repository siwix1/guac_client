import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct GuacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("Guacamole", id: "main") {
            Group {
                if let session = appState.activeSession {
                    ConnectionView(
                        session: session,
                        defaultUsername: appState.username
                    ) {
                        appState.disconnectSession()
                    }
                } else {
                    switch appState.authState {
                    case .needsCredentials, .needsTOTP, .failed:
                        LoginView(appState: appState)
                    case .authenticated:
                        ServerListView(appState: appState)
                    }
                }
            }
            .frame(minWidth: 800, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}
