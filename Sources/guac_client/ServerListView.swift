import SwiftUI

enum RecentConnections {
    private static let key = "recentConnectionIDs"
    private static let maxRecent = 5

    static func getRecent() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func markUsed(_ id: String) {
        var recent = getRecent()
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > maxRecent {
            recent = Array(recent.prefix(maxRecent))
        }
        UserDefaults.standard.set(recent, forKey: key)
    }
}

struct ServerListView: View {
    @Bindable var appState: AppState
    @State private var searchText = ""

    private var recentIDs: [String] { RecentConnections.getRecent() }

    private var filteredConnections: [GuacConnection] {
        let conns = searchText.isEmpty
            ? appState.connections
            : appState.connections.filter { $0.name.localizedCaseInsensitiveContains(searchText) }

        let recentSet = Set(recentIDs)
        let recent = recentIDs.compactMap { id in conns.first { $0.id == id } }
        let rest = conns.filter { !recentSet.contains($0.id) }
        return recent + rest
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Connections")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: {
                    Task { await appState.loadConnections() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)

                Button("Sign Out") {
                    appState.logout()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding()

            // Search
            TextField("Search...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            Divider()

            if appState.connections.isEmpty {
                ContentUnavailableView(
                    "No Connections",
                    systemImage: "server.rack",
                    description: Text("No remote desktops are available.")
                )
            } else {
                List(filteredConnections) { connection in
                    HStack {
                        Button {
                            RecentConnections.markUsed(connection.id)
                            appState.connect(to: connection)
                        } label: {
                            ConnectionRow(
                                connection: connection,
                                isRecent: recentIDs.contains(connection.id),
                                isActive: appState.activeSessions[connection.id] != nil
                            )
                        }
                        .buttonStyle(.plain)

                        if appState.activeSessions[connection.id] != nil {
                            Button {
                                appState.closeSession(connectionID: connection.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Disconnect")
                        }
                    }
                }
                .listStyle(.inset)
            }

            if let error = appState.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                }
                .foregroundStyle(.red)
                .font(.caption)
                .padding()
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

struct ConnectionRow: View {
    let connection: GuacConnection
    var isRecent: Bool = false
    var isActive: Bool = false

    var body: some View {
        HStack {
            Image(systemName: protocolIcon)
                .foregroundStyle(isActive ? .green : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(connection.connectionProtocol.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isActive {
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            if isRecent {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if connection.activeConnections > 0 {
                Label("\(connection.activeConnections)", systemImage: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var protocolIcon: String {
        switch connection.connectionProtocol.lowercased() {
        case "rdp": return "display"
        case "vnc": return "eye"
        case "ssh": return "terminal"
        case "telnet": return "text.cursor"
        default: return "network"
        }
    }
}
