import CryptoKit
import Foundation
import Security

/// Records which hosts the user has explicitly chosen to trust despite a TLS
/// validation failure, and why.
///
/// This exists because the Guacamole server's Let's Encrypt certificate has
/// lapsed before and will again. Rather than a blanket "accept anything" flag,
/// an exception is scoped to a single host *and* pinned to the exact
/// certificate the user saw when they approved it. If the certificate changes
/// — a renewal, or someone substituting their own — the exception no longer
/// applies and the user is asked again.
///
/// The pin is deliberately keyed on the public key rather than the whole
/// certificate: a certbot renewal normally reuses the same key pair, so a
/// routine renewal keeps working while a substituted certificate (which
/// necessarily carries a different key) does not.
struct CertificateException: Codable, Sendable, Equatable {
    let host: String
    /// SHA-256 of the leaf certificate's DER encoding, hex, colon-separated.
    let certificateFingerprint: String
    /// SHA-256 of the leaf's public key. Survives a same-key renewal.
    let publicKeyFingerprint: String
    /// Why validation failed when the user approved this, for display.
    let reason: String
    let approvedAt: Date
}

@MainActor
final class CertificateTrustStore {
    static let shared = CertificateTrustStore()

    private static let defaultsKey = "trustedCertificateExceptions"

    private var exceptions: [String: CertificateException] = [:]

    private init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: CertificateException].self, from: data)
        else { return }
        exceptions = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(exceptions) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    func exception(for host: String) -> CertificateException? {
        exceptions[host.lowercased()]
    }

    func store(_ exception: CertificateException) {
        exceptions[exception.host.lowercased()] = exception
        persist()
    }

    func remove(host: String) {
        exceptions.removeValue(forKey: host.lowercased())
        persist()
    }

    var all: [CertificateException] {
        exceptions.values.sorted { $0.host < $1.host }
    }
}

/// Details of a failed TLS validation, extracted for display to the user.
struct CertificateProblem: Sendable {
    let host: String
    let summary: String
    let issuer: String
    let notBefore: Date?
    let notAfter: Date?
    let certificateFingerprint: String
    let publicKeyFingerprint: String
    /// Human-readable reason validation failed, e.g. "The certificate expired
    /// on 17 August 2026."
    let reason: String

    var isExpired: Bool {
        guard let notAfter else { return false }
        return notAfter < Date()
    }

    /// True when the only thing wrong is the validity window. This is the case
    /// we're comfortable offering a bypass for; anything else (wrong hostname,
    /// untrusted issuer) is a different and more serious signal.
    let failureIsExpiryOnly: Bool
}

enum CertificateInspector {
    /// Evaluate a server trust and, if it fails, describe why.
    /// Returns nil when the trust is valid and no exception is needed.
    static func problem(for trust: SecTrust, host: String) -> CertificateProblem? {
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            return nil  // Valid — nothing to ask about.
        }

        let underlying = error.map { CFErrorCopyDescription($0) as String }
            ?? "The certificate could not be verified."

        guard let leaf = leafCertificate(from: trust) else {
            return CertificateProblem(
                host: host,
                summary: host,
                issuer: "Unknown",
                notBefore: nil,
                notAfter: nil,
                certificateFingerprint: "",
                publicKeyFingerprint: "",
                reason: underlying,
                failureIsExpiryOnly: false
            )
        }

        let der = SecCertificateCopyData(leaf) as Data
        let summary = SecCertificateCopySubjectSummary(leaf) as String? ?? host
        let (notBefore, notAfter) = validityWindow(of: leaf)
        let issuer = issuerName(of: leaf) ?? "Unknown"

        // Distinguish "expired but otherwise fine" from other failures. We
        // re-evaluate with the expiry check relaxed: if it then passes, the
        // date was the only problem.
        let expiryOnly = failsOnlyBecauseOfDate(trust: trust, notAfter: notAfter, host: host)

        let reason: String
        if let notAfter, notAfter < Date() {
            let fmt = DateFormatter()
            fmt.dateStyle = .long
            fmt.timeStyle = .short
            reason = "This certificate expired on \(fmt.string(from: notAfter))."
        } else if let notBefore, notBefore > Date() {
            let fmt = DateFormatter()
            fmt.dateStyle = .long
            reason = "This certificate is not valid until \(fmt.string(from: notBefore))."
        } else {
            reason = underlying
        }

        return CertificateProblem(
            host: host,
            summary: summary,
            issuer: issuer,
            notBefore: notBefore,
            notAfter: notAfter,
            certificateFingerprint: Self.fingerprint(of: der),
            publicKeyFingerprint: Self.publicKeyFingerprint(of: leaf) ?? "",
            reason: reason,
            failureIsExpiryOnly: expiryOnly
        )
    }

    /// Does the stored exception still cover what the server is presenting?
    static func exceptionApplies(_ exception: CertificateException, to trust: SecTrust) -> Bool {
        guard let leaf = leafCertificate(from: trust) else { return false }

        // A renewal that reuses the key pair keeps the same public key, so
        // accept on either match. Both are SHA-256 over stable bytes, so a
        // plain comparison is sufficient here.
        if let keyFP = publicKeyFingerprint(of: leaf),
           !exception.publicKeyFingerprint.isEmpty,
           keyFP == exception.publicKeyFingerprint {
            return true
        }

        let der = SecCertificateCopyData(leaf) as Data
        return fingerprint(of: der) == exception.certificateFingerprint
    }

    // MARK: - Certificate details

    private static func leafCertificate(from trust: SecTrust) -> SecCertificate? {
        copyChain(from: trust)?.first
    }

    /// Re-run evaluation as of a moment inside the old validity window. If the
    /// chain passes then, the date was the sole failure.
    ///
    /// This deliberately re-uses the *same SSL policy* (including the hostname
    /// check) rather than SecPolicyCreateBasicX509. A basic X509 policy does
    /// not verify hostnames, so a certificate served for the wrong host would
    /// pass the relaxed evaluation and be reported to the user as a harmless
    /// expiry — which is precisely the case we must not soft-pedal.
    private static func failsOnlyBecauseOfDate(
        trust: SecTrust, notAfter: Date?, host: String
    ) -> Bool {
        guard let notAfter, notAfter < Date() else { return false }
        guard let chain = copyChain(from: trust) else { return false }

        let policy = SecPolicyCreateSSL(true, host as CFString)
        var relaxed: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, policy, &relaxed) == errSecSuccess,
              let relaxed else { return false }

        SecTrustSetVerifyDate(relaxed, notAfter.addingTimeInterval(-3600) as CFDate)
        return SecTrustEvaluateWithError(relaxed, nil)
    }

    private static func copyChain(from trust: SecTrust) -> [SecCertificate]? {
        SecTrustCopyCertificateChain(trust) as? [SecCertificate]
    }

    private static func validityWindow(of certificate: SecCertificate) -> (Date?, Date?) {
        guard let values = SecCertificateCopyValues(
            certificate,
            [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray,
            nil
        ) as? [String: Any] else { return (nil, nil) }

        // These come back as seconds since the Apple reference date (2001).
        func date(_ oid: CFString) -> Date? {
            guard let entry = values[oid as String] as? [String: Any],
                  let seconds = entry[kSecPropertyKeyValue as String] as? Double
            else { return nil }
            return Date(timeIntervalSinceReferenceDate: seconds)
        }

        return (date(kSecOIDX509V1ValidityNotBefore), date(kSecOIDX509V1ValidityNotAfter))
    }

    private static func issuerName(of certificate: SecCertificate) -> String? {
        guard let values = SecCertificateCopyValues(
            certificate, [kSecOIDX509V1IssuerName] as CFArray, nil
        ) as? [String: Any],
        let issuer = values[kSecOIDX509V1IssuerName as String] as? [String: Any],
        let parts = issuer[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return nil }

        // Prefer the common name; fall back to the organisation.
        func value(forLabel label: String) -> String? {
            guard let match = parts.first(where: {
                ($0[kSecPropertyKeyLabel as String] as? String) == label
            }) else { return nil }
            return match[kSecPropertyKeyValue as String] as? String
        }
        return value(forLabel: "2.5.4.3") ?? value(forLabel: "2.5.4.10")
    }

    static func fingerprint(of data: Data) -> String {
        sha256Hex(data)
    }

    private static func publicKeyFingerprint(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        return sha256Hex(data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}
