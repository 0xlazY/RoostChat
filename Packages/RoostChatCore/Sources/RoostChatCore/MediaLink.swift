import Foundation

public enum MediaLink {
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic"]

    /// The attachment URL of a message: its XEP-0066 link, or a body that is
    /// nothing but a link to an image. Only https is accepted.
    public static func detect(oob: String?, body: String?) -> String? {
        if let oob, let url = httpsURL(oob) { return url.absoluteString }
        guard let body else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }), let url = httpsURL(trimmed), isImage(url.absoluteString) else { return nil }
        return url.absoluteString
    }

    public static func isImage(_ link: String) -> Bool {
        guard let url = URL(string: link) else { return false }
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    private static func httpsURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }
}
