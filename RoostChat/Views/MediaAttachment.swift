import ImageIO
import RoostChatCore
import SwiftUI
import UIKit

/// An attachment under a message. Images load automatically only if the user
/// opted in, since fetching a sender-chosen URL reveals the viewer's IP address.
struct MediaAttachment: View {
    let link: String

    @AppStorage(AppSettings.autoFetchMedia) private var autoFetch = false
    @State private var image: UIImage?
    @State private var loading = false
    @State private var failure: String?

    init(link: String) {
        self.link = link
    }

    private var url: URL? { URL(string: link) }
    private var isImage: Bool { MediaLink.isImage(link) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 280, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Image attachment")
            } else if loading {
                ProgressView()
            } else if isImage {
                Button {
                    load()
                } label: {
                    Label("Load image from \(url?.host ?? "link")", systemImage: "photo")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            if let failure {
                Text(verbatim: failure).font(.caption2).foregroundStyle(.red)
            }
            if let url, !isImage || failure != nil {
                Link(destination: url) {
                    Label(url.lastPathComponent.isEmpty ? link : url.lastPathComponent, systemImage: "paperclip")
                        .font(.caption)
                }
            }
        }
        .task(id: link) {
            if image == nil, let cached = MediaLoader.cached(link) {
                image = cached
            } else if image == nil, autoFetch, isImage {
                load()
            }
        }
    }

    private func load() {
        guard let url, !loading else { return }
        loading = true
        failure = nil
        Task {
            do {
                image = try await MediaLoader.load(url)
            } catch {
                failure = error.localizedDescription
            }
            loading = false
        }
    }
}

enum MediaError: LocalizedError {
    case notAnImage
    case tooLarge
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notAnImage: return "That link isn't an image."
        case .tooLarge: return "The image is over 20 MB."
        case .badResponse(let code): return "The server responded with \(code)."
        }
    }
}

/// Fetches untrusted remote images with a size cap, and decodes them at a bounded
/// resolution so that a small file can't expand into enormous memory use.
enum MediaLoader {
    private static let maxBytes = 20 * 1024 * 1024
    private static let cache = NSCache<NSString, UIImage>()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    static func cached(_ link: String) -> UIImage? {
        cache.object(forKey: link as NSString)
    }

    static func load(_ url: URL) async throws -> UIImage {
        let (bytes, response) = try await session.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MediaError.badResponse(http.statusCode)
        }
        guard response.mimeType?.hasPrefix("image/") == true else { throw MediaError.notAnImage }
        if response.expectedContentLength > Int64(maxBytes) { throw MediaError.tooLarge }

        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw MediaError.tooLarge }
        }
        guard let image = decode(data) else { throw MediaError.notAnImage }
        cache.setObject(image, forKey: url.absoluteString as NSString)
        return image
    }

    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}
