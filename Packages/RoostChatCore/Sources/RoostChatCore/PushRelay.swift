import Foundation

public enum PushRelay {
    /// A normalised relay domain, or nil if it can't be one. Blank means none.
    public static func normalizedDomain(_ input: String) -> String? {
        let domain = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."),
              domain.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return domain
    }

    /// APNs device tokens are sent as lowercase hex.
    public static func hexToken(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
