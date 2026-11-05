import Foundation
import SwiftData

@Model
final class StoredAccount {
    @Attribute(.unique) var jid: String
    var enabled: Bool
    /// Message archive position; nil until the first successful sync.
    var lastArchiveSync: Date?
    var createdAt: Date

    init(jid: String, enabled: Bool = true) {
        self.jid = jid
        self.enabled = enabled
        self.lastArchiveSync = nil
        self.createdAt = Date()
    }
}

@Model
final class StoredRoom {
    @Attribute(.unique) var key: String
    var account: String
    var room: String
    var nickname: String

    init(account: String, room: String, nickname: String) {
        self.key = StoredRoom.key(account: account, room: room)
        self.account = account
        self.room = room
        self.nickname = nickname
    }

    static func key(account: String, room: String) -> String { "\(account)|\(room)" }
}

enum ConversationKind: String, Codable {
    case chat
    case room
    case roomPrivate
}

@Model
final class StoredConversation {
    @Attribute(.unique) var id: String
    var account: String
    var peer: String
    var kindRaw: String
    var title: String
    var lastBody: String
    var lastTimestamp: Date
    var unread: Int

    init(account: String, peer: String, kind: ConversationKind, title: String) {
        self.id = StoredConversation.id(account: account, peer: peer)
        self.account = account
        self.peer = peer
        self.kindRaw = kind.rawValue
        self.title = title
        self.lastBody = ""
        self.lastTimestamp = .distantPast
        self.unread = 0
    }

    var kind: ConversationKind { ConversationKind(rawValue: kindRaw) ?? .chat }

    static func id(account: String, peer: String) -> String { "\(account)|\(peer)" }
}

enum DeliveryState: String, Codable {
    case received
    case sending
    case sent
    case delivered
    case failed
}

@Model
final class StoredMessage {
    var conversationID: String
    var dedupeKey: String
    var stanzaID: String?
    var sender: String
    var body: String
    var timestamp: Date
    var outgoing: Bool
    var stateRaw: String

    init(conversationID: String, dedupeKey: String, stanzaID: String?, sender: String, body: String, timestamp: Date, outgoing: Bool, state: DeliveryState) {
        self.conversationID = conversationID
        self.dedupeKey = dedupeKey
        self.stanzaID = stanzaID
        self.sender = sender
        self.body = body
        self.timestamp = timestamp
        self.outgoing = outgoing
        self.stateRaw = state.rawValue
    }

    var state: DeliveryState {
        get { DeliveryState(rawValue: stateRaw) ?? .received }
        set { stateRaw = newValue.rawValue }
    }
}

/// Where a chat screen points. Passed through navigation.
struct ChatRoute: Hashable, Identifiable {
    let account: String
    let peer: String
    let kind: ConversationKind
    let title: String

    var id: String { StoredConversation.id(account: account, peer: peer) }
}
