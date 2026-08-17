import AppKit
import Foundation

/// Presents the certificate problem to the user and returns their decision.
/// Runs on the main actor because it puts up a modal sheet.
@MainActor
enum CertificateApprovalPrompt {
    /// Serialises prompts so that the API call and the WebSocket connect —
    /// which race each other on the same host — don't stack two identical
    /// dialogs on screen. The second waiter re-checks the store and usually
    /// finds the first one already approved it.
    private static var inFlight: [String: Task<Bool, Never>] = [:]

    static func requestApproval(for problem: CertificateProblem) async -> Bool {
        // Already approved while we were waiting our turn?
        if let existing = CertificateTrustStore.shared.exception(for: problem.host),
           existing.certificateFingerprint == problem.certificateFingerprint
            || existing.publicKeyFingerprint == problem.publicKeyFingerprint {
            return true
        }

        if let running = inFlight[problem.host] {
            return await running.value
        }

        let task = Task<Bool, Never> { @MainActor in
            defer { inFlight[problem.host] = nil }
            return present(problem)
        }
        inFlight[problem.host] = task
        return await task.value
    }

    private static func present(_ problem: CertificateProblem) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Certificate problem for \(problem.host)"

        var body = problem.reason + "\n\n"
        body += "Issued to: \(problem.summary)\n"
        body += "Issued by: \(problem.issuer)\n"
        if let notAfter = problem.notAfter {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            body += "Expired: \(fmt.string(from: notAfter))\n"
        }
        body += "\nSHA-256: \(problem.certificateFingerprint)"

        if problem.failureIsExpiryOnly {
            body += "\n\nThe certificate is otherwise valid — it was issued by a "
            body += "trusted authority for this hostname, and only the expiry date "
            body += "has passed. Renewing it on the server is the real fix."
        } else {
            body += "\n\nThis is NOT a simple expiry. The certificate failed "
            body += "validation for another reason, which can indicate the "
            body += "connection is being intercepted. Only continue if you know "
            body += "why this server's certificate is untrusted."
        }

        alert.informativeText = body

        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Continue")
        // Cancel is first so Return/Escape both land on the safe choice.

        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return false }

        CertificateTrustStore.shared.store(
            CertificateException(
                host: problem.host,
                certificateFingerprint: problem.certificateFingerprint,
                publicKeyFingerprint: problem.publicKeyFingerprint,
                reason: problem.reason,
                approvedAt: Date()
            )
        )
        return true
    }
}

/// URLSession delegate used by both the REST API and the WebSocket tunnel.
///
/// Handles two things:
///  - suppressing HTTP redirects (Guacamole answers unauthenticated API calls
///    with an HTML login redirect, which we want to see as a failure)
///  - server-trust evaluation, with a user-approved exception path for the
///    recurring expired-certificate case
final class GuacURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        return nil  // Don't follow redirects
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await handle(challenge)
    }

    // Task-level variant: WebSocket tasks deliver the challenge here rather
    // than to the session-level method above.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await handle(challenge)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }

        let host = challenge.protectionSpace.host

        // Valid certificate — nothing to do.
        guard let problem = CertificateInspector.problem(for: trust, host: host) else {
            return (.performDefaultHandling, nil)
        }

        // Previously approved, and still the same certificate (or a renewal
        // that reused the key)? Proceed without bothering the user.
        if let exception = await CertificateTrustStore.shared.exception(for: host),
           CertificateInspector.exceptionApplies(exception, to: trust) {
            return (.useCredential, URLCredential(trust: trust))
        }

        // Otherwise ask. A stale exception for a *different* certificate is
        // intentionally not honoured — the user sees the new one and decides.
        if await CertificateApprovalPrompt.requestApproval(for: problem) {
            return (.useCredential, URLCredential(trust: trust))
        }

        return (.cancelAuthenticationChallenge, nil)
    }
}
