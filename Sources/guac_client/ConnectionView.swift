import SwiftUI
import UniformTypeIdentifiers

struct ConnectionView: View {
    let session: ConnectionSession
    let connectionID: String
    let defaultUsername: String
    let onDisconnect: () -> Void

    @State private var showCredentials = false
    @State private var credentialFields: [String] = []
    @State private var credentialValues: [String: String] = [:]
    @State private var isDroppingFile = false
    @State private var credentialError: String?
    /// Set once saved credentials have been auto-submitted, so a subsequent
    /// auth failure knows not to silently replay them again.
    @State private var didAutoSubmit = false

    /// UserDefaults key for saved remote credentials per connection
    private var credentialsSaveKey: String { "rdpCreds_\(connectionID)" }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RemoteDisplayView(nsView: session.nsView)

                if showCredentials {
                    Color.black.opacity(0.5)
                    RDPCredentialsView(
                        fields: credentialFields,
                        values: $credentialValues,
                        errorMessage: credentialError
                    ) {
                        UserDefaults.standard.set(credentialValues, forKey: credentialsSaveKey)
                        session.sendCredentials(credentialValues)
                        credentialError = nil
                        showCredentials = false
                    }
                }

                if isDroppingFile {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.1))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDroppingFile) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in
                            session.uploadFile(url: url)
                        }
                    }
                }
                return true
            }
        }
        .onAppear {
            session.onCredentialsRequired = { fields in
                credentialFields = fields
                // Load saved credentials for this connection
                let saved = UserDefaults.standard.dictionary(forKey: credentialsSaveKey) as? [String: String] ?? [:]
                for field in fields {
                    if let savedValue = saved[field], !savedValue.isEmpty {
                        credentialValues[field] = savedValue
                    } else if credentialValues[field] == nil {
                        credentialValues[field] = field == "username" ? defaultUsername : ""
                    }
                }
                // Auto-submit if we have all fields filled from saved values.
                // Only once per session: if the server rejects them we must
                // not silently replay the same bad credentials forever.
                let allFilled = fields.allSatisfy { !(credentialValues[$0] ?? "").isEmpty }
                if allFilled && !didAutoSubmit {
                    didAutoSubmit = true
                    session.sendCredentials(credentialValues)
                    UserDefaults.standard.set(credentialValues, forKey: credentialsSaveKey)
                } else {
                    showCredentials = true
                }
            }

            session.onServerError = { _, status in
                // 769 = CLIENT_UNAUTHORIZED: the remote host rejected the
                // login. guacd drops the tunnel immediately after, so we can't
                // retry in place — just discard the bad saved password so the
                // next connect prompts instead of replaying what just failed.
                // The message itself is surfaced by AppState on disconnect.
                if status == 769 {
                    var saved = UserDefaults.standard.dictionary(forKey: credentialsSaveKey) as? [String: String] ?? [:]
                    saved["password"] = ""
                    UserDefaults.standard.set(saved, forKey: credentialsSaveKey)
                }
            }
        }
    }

    private func pickFileForUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    session.uploadFile(url: url)
                }
            }
        }
    }
}

struct RDPCredentialsView: View {
    let fields: [String]
    @Binding var values: [String: String]
    /// Why the previous attempt failed, if it did.
    var errorMessage: String?
    let onSubmit: () -> Void
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Remote Login")
                .font(.title3)
                .fontWeight(.semibold)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(fields, id: \.self) { field in
                    if field == "password" {
                        SecureField(field.capitalized, text: binding(for: field))
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: field)
                            .onSubmit { submitOrAdvance(field) }
                    } else {
                        TextField(field.capitalized, text: binding(for: field))
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: field)
                            .onSubmit { submitOrAdvance(field) }
                    }
                }
            }

            Button("Connect", action: onSubmit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(30)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            // Focus password if username is pre-filled, otherwise first field
            if let first = fields.first {
                if first == "username" && !(values["username"] ?? "").isEmpty {
                    focusedField = fields.count > 1 ? fields[1] : first
                } else {
                    focusedField = first
                }
            }
        }
    }

    private func binding(for field: String) -> Binding<String> {
        Binding(
            get: { values[field] ?? "" },
            set: { values[field] = $0 }
        )
    }

    private func submitOrAdvance(_ current: String) {
        if let idx = fields.firstIndex(of: current), idx + 1 < fields.count {
            focusedField = fields[idx + 1]
        } else {
            onSubmit()
        }
    }
}
