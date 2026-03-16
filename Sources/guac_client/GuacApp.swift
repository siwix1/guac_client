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
                if appState.isLoading {
                    ProgressView("Restoring session...")
                        .frame(width: 380, height: 440)
                } else {
                    switch appState.authState {
                    case .needsCredentials, .needsTOTP, .failed:
                        LoginView(appState: appState)
                    case .authenticated:
                        ServerListView(appState: appState)
                    }
                }
            }
            .frame(minWidth: 400, minHeight: 300)
            .task {
                await appState.tryRestoreSession()
            }
        }
        .windowResizability(.contentMinSize)
    }
}
