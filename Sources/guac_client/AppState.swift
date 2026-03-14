import Foundation
import SwiftUI

@MainActor
@Observable
final class AppState {
    var authState: AuthState = .needsCredentials
    var connections: [GuacConnection] = []
    var isLoading = false
    var errorMessage: String?
    var activeSession: ConnectionSession?

    // Store login credentials for RDP pass-through
    private(set) var username: String = ""
    private(set) var password: String = ""

    private var api = GuacamoleAPI(baseURL: "")
    private(set) var token: AuthToken?
    private(set) var baseURL: String = ""

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

        let session = ConnectionSession(
            baseURL: baseURL,
            token: token,
            connection: connection,
            width: 1920,
            height: 1080
        )

        session.onDisconnect = { [weak self] error in
            if let error {
                self?.errorMessage = error
            }
            self?.activeSession = nil
        }

        session.start()
        activeSession = session
    }

    func disconnectSession() {
        activeSession?.stop()
        activeSession = nil
    }

    func logout() {
        disconnectSession()
        authState = .needsCredentials
        connections = []
        token = nil
        username = ""
        password = ""
        errorMessage = nil
    }
}
