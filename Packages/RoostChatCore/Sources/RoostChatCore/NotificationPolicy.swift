import Foundation

public enum RoomNotificationMode: String, CaseIterable, Sendable {
    case all, mentions, off
}

public enum NotificationPolicy {
    public static func shouldNotify(isRoom: Bool, mode: RoomNotificationMode, body: String, ownNickname: String?) -> Bool {
        guard isRoom else { return true }
        switch mode {
        case .all: return true
        case .off: return false
        case .mentions:
            guard let ownNickname, !ownNickname.isEmpty else { return false }
            return body.range(of: ownNickname, options: .caseInsensitive) != nil
        }
    }
}
