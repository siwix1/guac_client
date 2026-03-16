import SwiftUI

struct ConnectionView: View {
    let session: ConnectionSession
    let connectionID: String
    let defaultUsername: String
    let onDisconnect: () -> Void

    @State private var showCredentials = false
    @State private var credentialFields: [String] = []
    @State private var credentialValues: [String: String] = [:]

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
                        values: $credentialValues
                    ) {
                        UserDefaults.standard.set(credentialValues, forKey: credentialsSaveKey)
                        session.sendCredentials(credentialValues)
                        showCredentials = false
                    }
                }
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
                // Auto-submit if we have all fields filled from saved values
                if fields.allSatisfy({ !(credentialValues[$0] ?? "").isEmpty }) {
                    session.sendCredentials(credentialValues)
                    UserDefaults.standard.set(credentialValues, forKey: credentialsSaveKey)
                } else {
                    showCredentials = true
                }
            }
        }
    }
}

struct RDPCredentialsView: View {
    let fields: [String]
    @Binding var values: [String: String]
    let onSubmit: () -> Void
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Remote Login")
                .font(.title3)
                .fontWeight(.semibold)

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
