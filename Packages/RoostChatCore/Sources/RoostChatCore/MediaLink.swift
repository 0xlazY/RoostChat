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

public enum FileOfferText {
    /// A one-line description of a file offer. The name is chosen by the sender, so
    /// it's cut short and stripped of control and text-direction characters, which
    /// can disguise a file's real extension.
    public static func describe(name: String?, size: Int64?) -> String {
        let cleaned = (name ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        }
        var fileName = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        if fileName.count > 80 { fileName = String(fileName.prefix(80)) + "…" }
        let label = fileName.isEmpty ? "a file" : "“\(fileName)”"
        guard let size, size > 0 else { return label }
        return "\(label) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
    }

    /// Notification text for a message that is only a link to a file.
    public static func previewText(body: String, mediaURL: String?) -> String {
        guard let mediaURL, body.trimmingCharacters(in: .whitespacesAndNewlines) == mediaURL,
              let url = URL(string: mediaURL) else { return body }
        return "Sent \(describe(name: url.lastPathComponent, size: nil))"
    }
}
