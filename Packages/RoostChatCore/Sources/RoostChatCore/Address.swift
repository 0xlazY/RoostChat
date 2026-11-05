import Foundation

/// Validation and normalisation of user-typed XMPP addresses.
public enum Address {
    /// Returns a normalised `local@domain`, or nil when `input` isn't one.
    /// Rejects resources: accounts, contacts and rooms are all bare addresses.
    public static func normalizedBare(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let local = String(parts[0])
        let domain = String(parts[1])
        guard !local.isEmpty, !domain.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains(where: { $0.isWhitespace }),
              !domain.hasPrefix("."), !domain.hasSuffix(".") else { return nil }
        return "\(local.lowercased())@\(domain.lowercased())"
    }

    /// The bare part of a possibly-full JID, lowercased for comparison.
    public static func bare(_ jid: String) -> String {
        let withoutResource = jid.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? jid
        return withoutResource.lowercased()
    }

    /// The resource of a full JID, if it has one.
    public static func resource(_ jid: String) -> String? {
        guard let slash = jid.firstIndex(of: "/") else { return nil }
        let value = String(jid[jid.index(after: slash)...])
        return value.isEmpty ? nil : value
    }
}
