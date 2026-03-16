import Foundation

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        return nil  // Don't follow redirects
    }
}

struct AuthToken: Sendable {
    let token: String
    let dataSource: String
    let availableDataSources: [String]
}

struct GuacConnection: Identifiable, Sendable {
    let id: String
    let name: String
    let parentIdentifier: String
    let activeConnections: Int
    let connectionProtocol: String
    let dataSource: String
}

enum AuthState: Sendable {
    case needsCredentials
    case needsTOTP(username: String, password: String)
    case authenticated(AuthToken)
    case failed(String)
}

actor GuacamoleAPI {
    let baseURL: String
    private let session: URLSession

    init(baseURL: String) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.session = URLSession(configuration: .default, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// Build a request with headers that prevent HTML redirects
    private func apiRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Check if response is HTML instead of JSON (server redirect / proxy issue)
    private func isHTMLResponse(_ data: Data, _ response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/html") { return true }
        if let body = String(data: data, encoding: .utf8),
           body.trimmingCharacters(in: .whitespaces).hasPrefix("<!") || body.trimmingCharacters(in: .whitespaces).hasPrefix("<html") {
            return true
        }
        return false
    }

    func authenticate(username: String, password: String, totpCode: String? = nil) async throws -> AuthState {
        var request = apiRequest(url: URL(string: "\(baseURL)/api/tokens")!, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        var queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        if let totpCode {
            queryItems.append(URLQueryItem(name: "guac-totp", value: totpCode))
        }
        bodyComponents.queryItems = queryItems
        request.httpBody = bodyComponents.query?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        if isHTMLResponse(data, httpResponse) {
            return .failed("Server returned a login page instead of the API. Check your server URL — it should point to the Guacamole base path (e.g. https://host/guacamole)")
        }

        if httpResponse.statusCode == 403 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let expected = json["expected"] as? [[String: Any]] {
                let needsTotp = expected.contains { field in
                    (field["name"] as? String) == "guac-totp"
                }
                if needsTotp {
                    return .needsTOTP(username: username, password: password)
                }
            }
            return .failed("Invalid credentials")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            return .failed("Authentication failed (\(httpResponse.statusCode)): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["authToken"] as? String,
              let dataSource = json["dataSource"] as? String,
              let availableSources = json["availableDataSources"] as? [String] else {
            return .failed("Unexpected response format from server")
        }

        return .authenticated(AuthToken(
            token: token,
            dataSource: dataSource,
            availableDataSources: availableSources
        ))
    }

    func listConnections(token: AuthToken) async throws -> [GuacConnection] {
        var allConnections: [GuacConnection] = []

        for dataSource in token.availableDataSources {
            let connections = try await fetchConnections(token: token.token, dataSource: dataSource)
            allConnections.append(contentsOf: connections)
        }

        return allConnections
    }

    private func fetchConnections(token: String, dataSource: String) async throws -> [GuacConnection] {
        let url = URL(string: "\(baseURL)/api/session/data/\(dataSource)/connections?token=\(token)")!
        let request = apiRequest(url: url)

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard httpResponse.statusCode == 200, !isHTMLResponse(data, httpResponse) else { return [] }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var connections: [GuacConnection] = []
        for (identifier, value) in json {
            guard let conn = value as? [String: Any],
                  let name = conn["name"] as? String else { continue }
            let parentId = conn["parentIdentifier"] as? String ?? "ROOT"
            let activeConns = conn["activeConnections"] as? Int ?? 0
            let proto = conn["protocol"] as? String ?? "unknown"
            connections.append(GuacConnection(
                id: identifier,
                name: name,
                parentIdentifier: parentId,
                activeConnections: activeConns,
                connectionProtocol: proto,
                dataSource: dataSource
            ))
        }

        return connections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
