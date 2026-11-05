import Combine
import Foundation
import Network
import RoostChatCore
import SwiftData

/// All configured accounts, plus the app-wide state Pidgin keeps globally: one
/// status applied to every account.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [AccountSession] = []
    @Published private(set) var availability: Availability = .available
    @Published private(set) var statusMessage: String = ""

    /// The conversation on screen, which doesn't accumulate unread messages.
    var activeConversationID: String?

    private let store: ModelContext
    private var sessionObservers = [String: AnyCancellable]()
    private let pathMonitor = NWPathMonitor()
    private var networkWasUnavailable = false
    private var inForeground = true
    private var started = false

    private static let availabilityKey = "status.availability"
    private static let messageKey = "status.message"

    init(store: ModelContext) {
        self.store = store
        let defaults = UserDefaults.standard
        availability = defaults.string(forKey: Self.availabilityKey).flatMap(Availability.init(rawValue:)) ?? .available
        statusMessage = defaults.string(forKey: Self.messageKey) ?? ""
    }

    func start() {
        guard !started else { return }
        started = true
        let accounts = (try? store.fetch(FetchDescriptor<StoredAccount>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        for account in accounts {
            let session = makeSession(jid: account.jid)
            if account.enabled { session.connect() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.networkChanged(satisfied: satisfied)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "roostchat.network"))
    }

    func session(for jid: String) -> AccountSession? {
        sessions.first { $0.jid == jid }
    }

    func account(_ jid: String) -> StoredAccount? {
        var fetch = FetchDescriptor<StoredAccount>(predicate: #Predicate<StoredAccount> { $0.jid == jid })
        fetch.fetchLimit = 1
        return (try? store.fetch(fetch))?.first
    }

    // MARK: Accounts

    func addAccount(jid: String, password: String) -> String? {
        guard account(jid) == nil else { return "That account already exists." }
        guard Keychain.set(password, for: Keychain.accountKey(jid)) else {
            return "Could not save the password to the Keychain."
        }
        store.insert(StoredAccount(jid: jid))
        try? store.save()
        makeSession(jid: jid).connect()
        return nil
    }

    func updatePassword(jid: String, password: String) {
        Keychain.set(password, for: Keychain.accountKey(jid))
        guard let session = self.session(for: jid), account(jid)?.enabled == true else { return }
        session.connect()
    }

    func setEnabled(_ enabled: Bool, jid: String) {
        account(jid)?.enabled = enabled
        try? store.save()
        if enabled {
            session(for: jid)?.connect()
        } else {
            session(for: jid)?.disconnect()
        }
    }

    /// Removes the account and everything stored for it on this device. Nothing
    /// on the server is touched.
    func removeAccount(jid: String) {
        session(for: jid)?.disconnect()
        sessions.removeAll { $0.jid == jid }
        sessionObservers[jid] = nil
        Keychain.delete(Keychain.accountKey(jid))

        let rooms = (try? store.fetch(FetchDescriptor<StoredRoom>(predicate: #Predicate<StoredRoom> { $0.account == jid }))) ?? []
        for room in rooms {
            Keychain.delete(Keychain.roomKey(account: jid, room: room.room))
            store.delete(room)
        }
        let conversations = (try? store.fetch(FetchDescriptor<StoredConversation>(predicate: #Predicate<StoredConversation> { $0.account == jid }))) ?? []
        for conversation in conversations {
            deleteMessages(conversationID: conversation.id)
            store.delete(conversation)
        }
        if let stored = account(jid) { store.delete(stored) }
        try? store.save()
    }

    func deleteConversation(_ conversation: StoredConversation) {
        if conversation.kind == .room {
            session(for: conversation.account)?.leaveRoom(conversation.peer)
        }
        deleteMessages(conversationID: conversation.id)
        store.delete(conversation)
        try? store.save()
    }

    private func deleteMessages(conversationID: String) {
        try? store.delete(model: StoredMessage.self, where: #Predicate<StoredMessage> { $0.conversationID == conversationID })
    }

    func markRead(account: String, peer: String) {
        let id = StoredConversation.id(account: account, peer: peer)
        var fetch = FetchDescriptor<StoredConversation>(predicate: #Predicate<StoredConversation> { $0.id == id })
        fetch.fetchLimit = 1
        if let conversation = (try? store.fetch(fetch))?.first, conversation.unread != 0 {
            conversation.unread = 0
            try? store.save()
        }
    }

    // MARK: Status

    func setStatus(_ availability: Availability, message: String) {
        self.availability = availability
        statusMessage = message
        UserDefaults.standard.set(availability.rawValue, forKey: Self.availabilityKey)
        UserDefaults.standard.set(message, forKey: Self.messageKey)
        for session in sessions {
            session.setPresence(availability, message: message)
        }
    }

    // MARK: App lifecycle

    func enterForeground() {
        inForeground = true
        guard started else { return }
        for session in sessions where account(session.jid)?.enabled == true {
            session.connect()
        }
    }

    /// iOS suspends the app shortly after this, killing the socket regardless.
    /// Closing it deliberately lets the server resume the stream on return.
    func enterBackground() {
        inForeground = false
        for session in sessions {
            session.suspend()
        }
    }

    private func networkChanged(satisfied: Bool) {
        if !satisfied {
            networkWasUnavailable = true
        } else if networkWasUnavailable {
            networkWasUnavailable = false
            guard inForeground else { return }
            for session in sessions {
                session.networkBecameAvailable()
            }
        }
    }

    @discardableResult
    private func makeSession(jid: String) -> AccountSession {
        let session = AccountSession(jid: jid, store: store)
        session.activeConversationID = { [weak self] in self?.activeConversationID }
        session.setPresence(availability, message: statusMessage)
        // Views observe only the manager, so forward each account's changes.
        sessionObservers[jid] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessions.append(session)
        return session
    }
}
