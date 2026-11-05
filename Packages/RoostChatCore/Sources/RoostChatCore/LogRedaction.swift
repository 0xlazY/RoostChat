import Foundation

/// Scrubs XMPP stream text before it reaches the debug log, which people copy
/// and share. Credentials are always removed.
public enum LogRedaction {
    private static let credentialElements = ["auth", "response", "challenge", "success", "password"]

    public static func redact(_ xml: String, includeMessageBodies: Bool) -> String {
        var result = xml
        for name in credentialElements {
            result = replaceContent(of: name, in: result)
        }
        if !includeMessageBodies {
            result = replaceContent(of: "body", in: result)
        }
        return result
    }

    private static func replaceContent(of name: String, in text: String) -> String {
        let pattern = "(<\(name)(?:\\s[^>]*)?(?<!/)>)[\\s\\S]*?(</\(name)>)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "[redacted]" }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1[redacted]$2")
    }
}
