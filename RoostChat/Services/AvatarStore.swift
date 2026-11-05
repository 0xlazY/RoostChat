import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit

/// Profile pictures on disk, keyed by bare JID or `room/nick`. Images come from
/// other people, so they are size-capped and re-encoded at a small resolution.
@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()
    static let maxBytes = 2 * 1024 * 1024

    /// Bumped on each change so views showing avatars redraw.
    @Published private(set) var revision = 0

    private let cache = NSCache<NSString, UIImage>()
    private let directory: URL
    private var hashes: [String: String]
    private static let hashesKey = "avatars.hashes"

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hashes = UserDefaults.standard.dictionary(forKey: Self.hashesKey) as? [String: String] ?? [:]
    }

    func image(for key: String) -> UIImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: file(for: key).path) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// The hash of the stored picture. Nil if iOS has since cleared the file.
    func hash(for key: String) -> String? {
        guard FileManager.default.fileExists(atPath: file(for: key).path) else { return nil }
        return hashes[key]
    }

    func save(_ data: Data, hash: String?, for key: String) {
        guard data.count <= Self.maxBytes, let image = Self.decode(data), let png = image.pngData() else { return }
        do {
            try png.write(to: file(for: key), options: .atomic)
        } catch {
            return
        }
        cache.setObject(image, forKey: key as NSString)
        hashes[key] = hash ?? Self.sha1(data)
        UserDefaults.standard.set(hashes, forKey: Self.hashesKey)
        revision += 1
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: file(for: key))
        cache.removeObject(forKey: key as NSString)
        hashes[key] = nil
        UserDefaults.standard.set(hashes, forKey: Self.hashesKey)
        revision += 1
    }

    /// XEP-0153 identifies a picture by its SHA-1.
    static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func file(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".png")
    }

    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}

/// A round profile picture, or the name's initial on a colour derived from it.
struct AvatarView: View {
    let key: String
    let name: String
    var size: CGFloat = 40

    @ObservedObject private var store = AvatarStore.shared

    init(key: String, name: String, size: CGFloat = 40) {
        self.key = key
        self.name = name
        self.size = size
    }

    private static let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .red, .teal, .indigo]

    private var fallbackColor: Color {
        let total = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Self.palette[total % Self.palette.count]
    }

    var body: some View {
        Group {
            if let image = store.image(for: key) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    fallbackColor
                    Text(verbatim: name.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
