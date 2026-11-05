import Combine
import Foundation
import Martin

// Martin's DefaultRosterStore and DefaultRoomStore have no public initialiser,
// so the app provides equivalent in-memory stores.

final class AppRosterStore: RosterStore {
    typealias RosterItem = RosterItemBase

    private var roster = [JID: RosterItemBase]()
    private var version: String?
    private let queue = DispatchQueue(label: "roostchat.roster")

    func clear(for context: Context) {
        queue.async {
            self.version = nil
            self.roster.removeAll()
        }
    }

    func items(for context: Context) -> [RosterItemBase] {
        queue.sync { Array(roster.values) }
    }

    func item(for context: Context, jid: JID) -> RosterItemBase? {
        queue.sync { roster[jid] }
    }

    func updateItem(for context: Context, jid: JID, name: String?, subscription: RosterItemSubscription, groups: [String], ask: Bool, annotations: [RosterItemAnnotation]) {
        let item = RosterItemBase(jid: jid, name: name, subscription: subscription, groups: groups, ask: ask, annotations: annotations)
        queue.async { self.roster[jid] = item }
    }

    func deleteItem(for context: Context, jid: JID) {
        queue.async { self.roster.removeValue(forKey: jid) }
    }

    func version(for context: Context) -> String? {
        queue.sync { self.version }
    }

    func set(version: String?, for context: Context) {
        queue.async { self.version = version }
    }

    func initialize(context: Context) {}
    func deinitialize(context: Context) {}
}

final class AppRoomStore: RoomStore {
    typealias Room = RoomBase

    private let dispatcher = QueueDispatcher(label: "roostchat.rooms")
    private var rooms = [BareJID: RoomBase]()

    func rooms(for context: Context) -> [RoomBase] {
        dispatcher.sync { Array(rooms.values) }
    }

    func room(for context: Context, with jid: BareJID) -> RoomBase? {
        dispatcher.sync { rooms[jid] }
    }

    func createRoom(for context: Context, with jid: BareJID, nickname: String, password: String?) -> ConversationCreateResult<RoomBase> {
        dispatcher.sync {
            if let existing = rooms[jid] { return .found(existing) }
            let room = RoomBase(context: context, jid: jid, nickname: nickname, password: password, dispatcher: dispatcher)
            rooms[jid] = room
            return .created(room)
        }
    }

    func close(room: RoomBase) -> Bool {
        dispatcher.sync { rooms.removeValue(forKey: room.jid) != nil }
    }

    func initialize(context: Context) {}
    func deinitialize(context: Context) {}
}

/// Martin drops a body-less message unless a chat object already exists for that
/// contact. The app sends through its own path, so usually none does, and typing
/// notifications were lost. This reports them before Martin can discard them.
final class ChatStateMessageModule: MessageModule {
    let chatStates = PassthroughSubject<Message, Never>()

    override func process(stanza: Stanza) {
        if let message = stanza as? Message, message.chatState != nil, message.type != .error {
            chatStates.send(message)
        }
        super.process(stanza: stanza)
    }
}

/// Martin processes any message carrying a carbons element without checking who
/// sent it, which would let any contact forge messages in another conversation.
/// Per XEP-0280 a carbon is only valid from the account's own bare JID (or with
/// no `from`, which means the same thing).
final class VerifiedCarbonsModule: MessageCarbonsModule {
    override func process(stanza message: Stanza) throws {
        guard let own = context?.userBareJid else { return }
        if let from = message.from, from.bareJid != own || from.resource != nil { return }
        try super.process(stanza: message)
    }
}
