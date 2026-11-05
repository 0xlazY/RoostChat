import Foundation

/// What to do with the certificate a server presented.
public enum TLSDecision: Equatable, Sendable {
    /// Chains to a trusted root and matches the XMPP domain.
    case acceptVerified
    /// Not verifiable, but it's the certificate the user already accepted.
    case acceptPinned
    /// Not verifiable, and the first one seen for this account: remember it.
    case acceptAndPin
    case rejectUnverified
    /// Not verifiable, and different from the accepted one. Could be interception.
    case rejectChanged(pinned: String)

    public var accepts: Bool {
        switch self {
        case .acceptVerified, .acceptPinned, .acceptAndPin: return true
        case .rejectUnverified, .rejectChanged: return false
        }
    }
}

public enum TLSPolicy {
    public static func decide(systemTrusted: Bool, allowUnverified: Bool, pinned: String?, seen: String?) -> TLSDecision {
        if systemTrusted { return .acceptVerified }
        guard allowUnverified, let seen else { return .rejectUnverified }
        guard let pinned else { return .acceptAndPin }
        return pinned.caseInsensitiveCompare(seen) == .orderedSame ? .acceptPinned : .rejectChanged(pinned: pinned)
    }
}

public enum ServerAddress {
    /// Validates a user-typed host and port. An empty port means the default.
    public static func parse(host: String, port: String, directTLS: Bool) -> (host: String, port: Int)? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedHost.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }) else { return nil }
        if trimmedPort.isEmpty { return (trimmedHost, directTLS ? 5223 : 5222) }
        guard let value = Int(trimmedPort), (1...65535).contains(value) else { return nil }
        return (trimmedHost, value)
    }
}
