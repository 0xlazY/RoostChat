import CryptoKit
import Foundation
import Martin
import RoostChatCore
import Security

/// What was learned from a server's certificate.
struct TLSObservation {
    let fingerprint: String?
    let subject: String?
    let systemError: String?
}

/// Builds the check run on each TLS handshake. System validation against the
/// XMPP domain comes first; pinning only applies to certificates that fail it.
/// The checked name is the domain even with a custom host, as XMPP requires.
func makeTLSValidator(domain: String, allowUnverified: Bool, pinned: String?,
                      report: @escaping (TLSObservation, TLSDecision) -> Void) -> (SecTrust) -> Bool {
    return { trust in
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, domain as CFString))
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)

        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
        let leaf = chain?.first
        var fingerprint: String?
        if let leaf {
            let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        }
        let observation = TLSObservation(fingerprint: fingerprint,
                                         subject: leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? },
                                         systemError: error.map { CFErrorCopyDescription($0) as String })
        let decision = TLSPolicy.decide(systemTrusted: trusted, allowUnverified: allowUnverified, pinned: pinned, seen: fingerprint)
        report(observation, decision)
        return decision.accepts
    }
}

struct TLSRequiredError: LocalizedError {
    var errorDescription: String? {
        "The server did not offer TLS, so your password was not sent. This can also mean someone is tampering with the connection."
    }
}

/// Martin authenticates in plaintext when a server doesn't advertise STARTTLS,
/// which lets anyone on the network path strip TLS and capture the login. This
/// refuses to start authentication on an unencrypted connection.
final class TLSRequiredAuthModule: AuthModule {
    override func login() {
        guard (context as? XMPPClient)?.connector?.activeFeatures.contains(.TLS) == true else {
            update(state: .error(TLSRequiredError()))
            return
        }
        super.login()
    }
}

/// Connects to a user-chosen server instead of looking up DNS records.
final class FixedServerResolver: DNSSrvResolver {
    private let account: String
    private let host: String
    private let port: Int
    private let directTLS: Bool

    init(account: String, host: String, port: Int, directTLS: Bool) {
        self.account = account
        self.host = host
        self.port = port
        self.directTLS = directTLS
    }

    func resolve(domain: String, for jid: BareJID, completionHandler: @escaping (Result<XMPPSrvResult, DNSError>) -> Void) {
        DebugLog.shared.add(.connection, account: account, "Using custom server \(host):\(port)")
        let record = XMPPSrvRecord(port: port, weight: 0, priority: 0, target: host, directTls: directTLS)
        completionHandler(.success(XMPPSrvResult(domain: domain, records: [record])))
    }

    func markAsInvalid(for domain: String, record: XMPPSrvRecord, for time: TimeInterval) {}
    func markAsInvalid(for domain: String, host: String, port: Int, for time: TimeInterval) {}
}

/// The normal DNS lookup, recording what it found for the diagnostics screen.
final class LoggingDNSResolver: DNSSrvResolver {
    private let inner = XMPPDNSSrvResolver(directTlsEnabled: true)
    private let account: String
    private let report: (String) -> Void

    init(account: String, report: @escaping (String) -> Void) {
        self.account = account
        self.report = report
    }

    func resolve(domain: String, for jid: BareJID, completionHandler: @escaping (Result<XMPPSrvResult, DNSError>) -> Void) {
        let account = self.account
        let report = self.report
        inner.resolve(domain: domain, for: jid) { result in
            switch result {
            case .success(let found):
                let chosen = found.record()?.description ?? "No records, trying \(domain):5222"
                DebugLog.shared.add(.connection, account: account, "DNS: \(found.description)")
                report(chosen)
            case .failure(let error):
                DebugLog.shared.add(.connection, account: account, "DNS lookup failed: \(error), trying \(domain):5222")
                report("DNS lookup failed, trying \(domain):5222")
            }
            completionHandler(result)
        }
    }

    func markAsInvalid(for domain: String, record: XMPPSrvRecord, for time: TimeInterval) {
        inner.markAsInvalid(for: domain, record: record, for: time)
    }

    func markAsInvalid(for domain: String, host: String, port: Int, for time: TimeInterval) {
        inner.markAsInvalid(for: domain, host: host, port: port, for: time)
    }
}

/// Copies stream traffic to the debug log, redacted.
final class StreamDebugLogger: StreamLogger {
    private let account: String

    init(account: String) {
        self.account = account
    }

    func incoming(_ value: StreamEvent) {
        record("IN", value)
    }

    func outgoing(_ value: StreamEvent) {
        record("OUT", value)
    }

    private func record(_ direction: String, _ event: StreamEvent) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppSettings.loggingEnabled) else { return }
        let text: String
        switch event {
        case .stanza(let stanza):
            text = LogRedaction.redact(stanza.description, includeMessageBodies: defaults.bool(forKey: AppSettings.logBodies))
        case .streamOpen(let attributes):
            text = "<stream:stream \(attributes.map { "\($0.key)='\($0.value)'" }.sorted().joined(separator: " "))>"
        case .streamStart:
            text = "<stream start>"
        case .streamClose:
            text = "</stream:stream>"
        case .streamTerminate:
            text = "<stream terminated>"
        }
        DebugLog.shared.add(.stream, account: account, "\(direction) \(text)")
    }
}
