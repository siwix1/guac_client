import SwiftUI

struct LoginView: View {
    @Bindable var appState: AppState

    @State private var serverURL = UserDefaults.standard.string(forKey: "savedServerURL") ?? ""
    @State private var username = UserDefaults.standard.string(forKey: "savedUsername") ?? ""
    @State private var password = ""
    @State private var totpCode = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case serverURL, username, password, totp
    }

    private var needsTOTP: Bool {
        if case .needsTOTP = appState.authState { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Guacamole Remote Desktop")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 12) {
                if !needsTOTP {
                    TextField("Server URL", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .serverURL)
                        .onSubmit { focusedField = .username }

                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .password)
                        .onSubmit { performLogin() }
                } else {
                    Text("Enter your TOTP code")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField("6-digit code", text: $totpCode)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .totp)
                        .onSubmit { performLogin() }
                        .onAppear { focusedField = .totp }
                }
            }
            .frame(maxWidth: 280)

            if let error = appState.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }

            Button(action: performLogin) {
                if appState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(needsTOTP ? "Verify" : "Sign In")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isLoading || !isFormValid)
            .keyboardShortcut(.defaultAction)

            if needsTOTP {
                Button("Back") {
                    appState.authState = .needsCredentials
                    totpCode = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(width: 380, height: 440)
        .onAppear {
            if serverURL.isEmpty {
                focusedField = .serverURL
            } else if username.isEmpty {
                focusedField = .username
            } else {
                focusedField = .password
            }
        }
    }

    private var isFormValid: Bool {
        if needsTOTP {
            return !totpCode.isEmpty
        }
        return !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
    }

    private func performLogin() {
        guard isFormValid else { return }
        Task {
            UserDefaults.standard.set(serverURL, forKey: "savedServerURL")
            if case .needsTOTP(let user, let pass) = appState.authState {
                UserDefaults.standard.set(user, forKey: "savedUsername")
                await appState.login(serverURL: serverURL, username: user, password: pass, totpCode: totpCode)
            } else {
                await appState.login(serverURL: serverURL, username: username, password: password)
            }
        }
    }
}
