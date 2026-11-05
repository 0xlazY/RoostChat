import Foundation

enum AppSettings {
    static let keepAlive = "background.keepAlive"
    static let notificationsEnabled = "notifications.enabled"
    static let notificationPreview = "notifications.preview"
    static let notificationRooms = "notifications.rooms"
    static let autoFetchMedia = "media.autoFetch"
    static let logStream = "debug.logStream"
    static let logBodies = "debug.logBodies"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            keepAlive: true,
            notificationsEnabled: true,
            notificationPreview: true,
            notificationRooms: "mentions",
            autoFetchMedia: false,
            logStream: true,
            logBodies: false,
        ])
    }
}

enum LogCategory: String, CaseIterable, Identifiable {
    case connection = "Connection"
    case stream = "XML"
    case app = "App"

    var id: String { rawValue }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let category: LogCategory
    let account: String?
    let text: String

    var line: String {
        let time = date.formatted(date: .omitted, time: .standard)
        return "\(time) [\(category.rawValue)]\(account.map { " \($0)" } ?? "") \(text)"
    }
}

/// An in-memory ring of recent events. Never written to disk, gone on relaunch.
/// Safe to call from any thread; Martin logs from its own queues.
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    private static let capacity = 2000

    @Published private(set) var entries: [LogEntry] = []

    func add(_ category: LogCategory, account: String? = nil, _ text: String) {
        let entry = LogEntry(date: Date(), category: category, account: account, text: text)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > Self.capacity {
                self.entries.removeFirst(self.entries.count - Self.capacity)
            }
        }
    }

    func clear() {
        entries.removeAll()
    }
}
