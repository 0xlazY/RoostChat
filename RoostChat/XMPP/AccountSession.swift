import Combine
import Foundation
import Martin
import RoostChatCore
import SwiftData

enum Availability: String, CaseIterable, Identifiable {
    case available, away, xa, dnd, offline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .available: return "Available"
        case .away: return "Away"
        case .xa: return "Extended Away"
        case .dnd: return "Do Not Disturb"
        case .offline: return "Offline"
        }
    }

    fileprivate init(show: Presence.Show?) {
        switch show {
        case .chat, .online: self = .available
        case .away: self = .away
        case .xa: self = .xa
        case .dnd: self = .dnd
        case .none: self = .offline
        }
    }

    fileprivate var show: Presence.Show {
        switch self {
        case .available, .offline: return .online
        case .away: return .away
        case .xa: return .xa
        case .dnd: return .dnd
        }
    }
}

struct Buddy: Identifiable, Equatable {
    let account: String
    let jid: String
    let name: String
    let groups: [String]
    let availability: Availability
    let statusText: String?
    let awaitingApproval: Bool

    var id: String { "\(account)|\(jid)" }
}

enum ConnectionStatus: Equatable {
    case offline
    case connecting
    case online
    case failed(String)

    var label: String {
        switch self {
        case .offline: return "Offline"
        case .connecting: return "Connecting…"
        case .online: return "Online"
        case .failed(let reason): return reason
        }
    }
}

enum RoomStatus: Equatable {
    case joining
    case joined
    case failed(String)
}

struct RoomInvite: Identifiable, Equatable {
    let room: String
    let inviter: String?
    let password: String?

    var id: String { room }
}

/// One XMPP account: owns its client, and turns protocol events into stored
/// messages and published UI state. Martin delivers events on its own queues, so
/// everything is hopped to the main actor before touching state.
@MainActor
final class AccountSession: ObservableObject, Identifiable {
    let jid: String
    nonisolated var id: String { jid }

    @Published private(set) var status: ConnectionStatus = .offline
    @Published private(set) var buddies: [Buddy] = []
    @Published private(set) var subscriptionRequests: [String] = []
    @Published private(set) var invites: [RoomInvite] = []
    @Published private(set) var typingPeers: Set<String> = []
    @Published private(set) var roomStatus: [String: RoomStatus] = [:]
    @Published private(set) var occupants: [String: [String]] = [:]

    /// Whichever conversation is on screen; it doesn't accumulate unread messages.
    var activeConversationID: () -> String? = { nil }

    private let client: XMPPClient
    private let store: ModelContext
    private let rosterModule: RosterModule
    private let presenceModule: PresenceModule
    private let mucModule: MucModule
    private let mamModule: MessageArchiveManagementModule
    private let carbonsModule: MessageCarbonsModule

    private var cancellables = Set<AnyCancellable>()
    private var roomCancellables = [String: AnyCancellable]()
    private let rosterRefresh = PassthroughSubject<Void, Never>()
    private var knownRooms = Set<String>()
    private var archiveQueryIDs = Set<String>()

    private var wantsConnection = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var archiveSyncPending = false
    private var archiveSyncRunning = false

    init(jid: String, store: ModelContext) {
        self.jid = jid
        self.store = store
        let client = XMPPClient()
        self.client = client

        // Order matters: several modules look up earlier ones when registered.
        let modules = client.modulesManager
        modules.register(StreamFeaturesModule())
        modules.register(AuthModule())
        modules.register(SaslModule())
        modules.register(ResourceBinderModule())
        modules.register(SessionEstablishmentModule())
        modules.register(DiscoveryModule(identity: DiscoveryModule.Identity(category: "client", type: "phone", name: "RoostChat")))
        modules.register(SoftwareVersionModule(version: SoftwareVersionModule.SoftwareVersion(name: "RoostChat", version: "0.1", os: nil)))
        modules.register(PingModule())
        rosterModule = modules.register(RosterModule(rosterManager: RosterManagerBase<AppRosterStore>(store: AppRosterStore())))
        presenceModule = modules.register(PresenceModule())
        modules.register(CapabilitiesModule())
        let messageModule = modules.register(MessageModule(chatManager: DefaultChatManager(store: DefaultChatStore())))
        let verifiedCarbons = modules.register(VerifiedCarbonsModule())
        carbonsModule = verifiedCarbons
        mamModule = modules.register(MessageArchiveManagementModule())
        mucModule = modules.register(MucModule(roomManager: RoomManagerBase<AppRoomStore>(store: AppRoomStore())))
        modules.register(StreamManagementModule())
        let receipts = modules.register(MessageDeliveryReceiptsModule())
        modules.register(ChatStateNotificationsModule())

        client.connectionConfiguration.userJid = BareJID(jid)

        knownRooms = Set(storedRooms().map(\.room))

        // These two fire on Martin's queues, so they must not touch actor state.
        let refresh = rosterRefresh

        client.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handle(state: state) }
            .store(in: &cancellables)

        messageModule.messagesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] received in self?.handleLive(received.message) }
            .store(in: &cancellables)

        carbonsModule.carbonsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] carbon in
                self?.handleCarbon(carbon.message, sent: carbon.action == .sent)
            }
            .store(in: &cancellables)

        mamModule.archivedMessagesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] archived in self?.handleArchived(archived) }
            .store(in: &cancellables)

        mamModule.$availableVersions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] versions in
                if !versions.isEmpty { self?.syncArchiveIfNeeded() }
            }
            .store(in: &cancellables)

        mucModule.messagesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] received in
                self?.handleRoom(received.message, room: received.room)
            }
            .store(in: &cancellables)

        mucModule.inivitationsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] invitation in
                self?.addInvite(room: Address.bare(invitation.roomJid.stringValue), inviter: invitation.inviter?.stringValue, password: invitation.password)
            }
            .store(in: &cancellables)

        receipts.receiptsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] receipt in
                self?.handleReceipt(from: receipt.message.from, messageID: receipt.messageId)
            }
            .store(in: &cancellables)

        presenceModule.subscriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard case .subscribe = change.action else { return }
                self?.addSubscriptionRequest(Address.bare(change.jid.stringValue))
            }
            .store(in: &cancellables)

        presenceModule.presencePublisher
            .sink { _ in refresh.send(()) }
            .store(in: &cancellables)

        rosterModule.events
            .sink { _ in refresh.send(()) }
            .store(in: &cancellables)

        rosterRefresh
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadBuddies() }
            .store(in: &cancellables)
    }

    // MARK: Connection lifecycle

    func connect() {
        wantsConnection = true
        reconnectTask?.cancel()
        reconnectTask = nil
        guard case .disconnected = client.state else { return }
        guard let password = Keychain.get(Keychain.accountKey(jid)) else {
            status = .failed("Password missing. Edit the account to set it.")
            wantsConnection = false
            return
        }
        client.connectionConfiguration.credentials = .password(password: password, authenticationName: nil, cache: nil)
        status = .connecting
        client.login()
    }

    /// Closes the socket without ending the XMPP session, so that if the server
    /// supports stream management the next connect resumes where this left off.
    func suspend() {
        stop(force: true)
    }

    func disconnect() {
        stop(force: false)
    }

    private func stop(force: Bool) {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        Task { [client] in
            try? await client.disconnect(force: force)
        }
    }

    /// Network came back: don't wait out the backoff timer.
    func networkBecameAvailable() {
        guard wantsConnection else { return }
        reconnectAttempt = 0
        connect()
    }

    private func handle(state: XMPPClient.State) {
        switch state {
        case .connecting:
            status = .connecting
        case .connected(let resumed):
            status = .online
            reconnectAttempt = 0
            if !resumed {
                carbonsModule.enable(nil)
                rejoinRooms()
                archiveSyncPending = true
                syncArchiveIfNeeded()
            }
        case .disconnecting:
            break
        case .disconnected(let reason):
            typingPeers = []
            rosterRefresh.send(())
            handleDisconnect(reason)
        }
    }

    private func handleDisconnect(_ reason: XMPPClient.State.DisconnectionReason) {
        for room in knownRooms where roomStatus[room] == .joined {
            roomStatus[room] = nil
        }
        switch reason {
        case .authenticationFailure:
            // Retrying a wrong password can get the account locked.
            wantsConnection = false
            status = .failed(reason.localizedDescription)
        case .sslCertError:
            // Never retried or bypassed: this may be an interception attempt.
            wantsConnection = false
            status = .failed("The server's TLS certificate could not be verified. Not connecting.")
        case .none:
            if wantsConnection { scheduleReconnect() } else { status = .offline }
        default:
            if wantsConnection {
                status = .failed(reason.localizedDescription)
                scheduleReconnect()
            } else {
                status = .offline
            }
        }
    }

    private func scheduleReconnect() {
        let delay = Reconnect.delay(attempt: reconnectAttempt, jitter: Double.random(in: 0...1))
        reconnectAttempt += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    // MARK: Presence & roster

    func setPresence(_ availability: Availability, message: String?) {
        let text = message?.isEmpty == true ? nil : message
        presenceModule.setPresence(show: availability.show, status: text, priority: nil)
    }

    private func reloadBuddies() {
        let items = rosterModule.rosterManager.items(for: client)
        let updated = items.map { item -> Buddy in
            let bare = item.jid.bareJid
            let presence = presenceModule.store.bestPresence(for: bare, context: client)
            let isConnected = client.state == .connected()
            return Buddy(account: jid,
                         jid: bare.stringValue,
                         name: item.name ?? bare.stringValue,
                         groups: item.groups,
                         availability: isConnected ? Availability(show: presence?.show) : .offline,
                         statusText: isConnected ? presence?.status : nil,
                         awaitingApproval: item.ask)
        }
        buddies = updated.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func addBuddy(_ address: String, name: String?, group: String?) {
        let contact = JID(address)
        let groups = group.map { [$0] } ?? []
        rosterModule.addItem(jid: contact, name: name, groups: groups, completionHandler: { [presenceModule] result in
            if case .success = result {
                presenceModule.subscribe(to: contact)
            }
        })
    }

    func removeBuddy(_ address: String) {
        rosterModule.removeItem(jid: JID(address), completionHandler: nil)
    }

    func approveSubscription(_ address: String) {
        let contact = JID(address)
        presenceModule.subscribed(by: contact)
        // Ask back unless we're already subscribed, as most clients do.
        if rosterModule.rosterManager.item(for: client, jid: contact)?.subscription.isTo != true {
            presenceModule.subscribe(to: contact)
        }
        subscriptionRequests.removeAll { $0 == address }
    }

    func denySubscription(_ address: String) {
        presenceModule.unsubscribed(by: JID(address))
        subscriptionRequests.removeAll { $0 == address }
    }

    private func addSubscriptionRequest(_ address: String) {
        if !subscriptionRequests.contains(address) {
            subscriptionRequests.append(address)
        }
    }

    // MARK: Sending

    func send(_ text: String, route: ChatRoute) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let id = UUID().uuidString
        let conversation = conversationRecord(peer: route.peer, kind: route.kind, title: route.title)
        let sender: String
        if route.kind == .room {
            sender = storedRooms().first { $0.room == route.peer }?.nickname ?? "me"
        } else {
            sender = "me"
        }
        let record = StoredMessage(conversationID: conversation.id,
                                   dedupeKey: MessageRouting.dedupeKey(originID: id, stanzaID: id, from: jid, timestamp: nil, body: body),
                                   stanzaID: id, sender: sender, body: body, timestamp: Date(), outgoing: true, state: .sending)
        store.insert(record)
        touch(conversation, body: body, timestamp: record.timestamp)
        transmit(record, route: route)
    }

    /// Sends a message whose earlier attempt failed.
    func resend(_ record: StoredMessage, route: ChatRoute) {
        record.state = .sending
        record.timestamp = Date()
        save()
        transmit(record, route: route)
    }

    private func transmit(_ record: StoredMessage, route: ChatRoute) {
        guard client.state == .connected(), route.kind != .room || roomStatus[route.peer] == .joined else {
            record.state = .failed
            save()
            return
        }
        let message = Message()
        message.to = JID(route.peer)
        message.id = record.stanzaID
        message.originId = record.stanzaID
        message.body = record.body
        switch route.kind {
        case .room:
            message.type = .groupchat
        case .roomPrivate:
            message.type = .chat
            message.addChild(Element(name: "x", xmlns: "http://jabber.org/protocol/muc#user"))
        case .chat:
            message.type = .chat
            message.chatState = .active
            message.messageDelivery = .request
        }
        client.writer.write(message, writeCompleted: { [weak self] result in
            let succeeded: Bool
            if case .success = result { succeeded = true } else { succeeded = false }
            Task { @MainActor [weak self] in
                self?.finishedWriting(record, succeeded: succeeded)
            }
        })
    }

    private func finishedWriting(_ record: StoredMessage, succeeded: Bool) {
        // A delivery receipt or room reflection may already have arrived.
        if record.state == .sending {
            record.state = succeeded ? .sent : .failed
            save()
        }
    }

    func sendChatState(composing: Bool, to peer: String) {
        guard client.state == .connected() else { return }
        let message = Message()
        message.to = JID(peer)
        message.type = .chat
        message.id = UUID().uuidString
        message.chatState = composing ? .composing : .paused
        client.writer.write(message)
    }

    // MARK: Receiving

    private func handleLive(_ message: Message) {
        if message.type == .error {
            handleBounce(message)
            return
        }
        if let from = message.from, let state = message.chatState {
            let peer = Address.bare(from.stringValue)
            if state == .composing {
                typingPeers.insert(peer)
            } else {
                typingPeers.remove(peer)
            }
        }
        storeRouted(message, source: .live, timestamp: MessageRouting.effectiveTimestamp(delay: message.delay?.stamp))
    }

    private func handleCarbon(_ message: Message, sent: Bool) {
        storeRouted(message, source: sent ? .carbonSent : .carbonReceived,
                    timestamp: MessageRouting.effectiveTimestamp(delay: message.delay?.stamp))
    }

    private func handleArchived(_ archived: MessageArchiveManagementModule.ArchivedMessageReceived) {
        // Only results of queries we issued, from our own account's archive.
        guard archiveQueryIDs.contains(archived.query.id),
              archived.source.stringValue.lowercased() == jid else { return }
        storeRouted(archived.message, source: .archive,
                    timestamp: MessageRouting.effectiveTimestamp(delay: archived.timestamp),
                    countsAsUnread: account()?.lastArchiveSync != nil)
    }

    private func storeRouted(_ message: Message, source: MessageSource, timestamp: Date, countsAsUnread: Bool = true) {
        let envelope = MessageEnvelope(from: message.from?.stringValue, to: message.to?.stringValue,
                                       type: message.type?.rawValue, body: message.body)
        guard let body = message.body else { return }
        let key = MessageRouting.dedupeKey(originID: message.originId, stanzaID: message.id,
                                           from: envelope.from, timestamp: message.delay?.stamp, body: body)

        switch MessageRouting.route(envelope, source: source, account: jid, knownRooms: knownRooms) {
        case .ignore:
            return
        case .chat(let peer, let outgoing):
            let title = rosterName(peer) ?? peer
            insert(peer: peer, kind: .chat, title: title, sender: outgoing ? "me" : title, body: body,
                   timestamp: timestamp, outgoing: outgoing, key: key, stanzaID: message.id, countsAsUnread: countsAsUnread)
            if !outgoing { typingPeers.remove(peer) }
        case .roomPrivate(let peer, _, let nick, let outgoing):
            insert(peer: peer, kind: .roomPrivate, title: nick, sender: outgoing ? "me" : nick, body: body,
                   timestamp: timestamp, outgoing: outgoing, key: key, stanzaID: message.id, countsAsUnread: countsAsUnread)
        }
    }

    private func handleRoom(_ message: Message, room: RoomProtocol) {
        if message.type == .error {
            handleBounce(message)
            return
        }
        guard let body = message.body, !body.isEmpty else { return }
        let roomJID = room.jid.stringValue
        let nick = message.from?.resource
        let stamp = message.delay?.stamp
        let key = MessageRouting.dedupeKey(originID: message.originId, stanzaID: message.id,
                                           from: message.from?.stringValue, timestamp: stamp, body: body)
        insert(peer: roomJID, kind: .room, title: room.jid.localPart ?? roomJID, sender: nick ?? roomJID, body: body,
               timestamp: MessageRouting.effectiveTimestamp(delay: stamp), outgoing: nick == room.nickname,
               key: key, stanzaID: message.id, countsAsUnread: stamp == nil)
    }

    /// A send we made was rejected. Mark that message rather than show the echo.
    private func handleBounce(_ message: Message) {
        guard let id = message.id, let from = message.from else { return }
        for peer in peerCandidates(from) {
            let conversationID = StoredConversation.id(account: jid, peer: peer)
            if let record = findMessage(conversationID: conversationID, stanzaID: id), record.outgoing {
                record.state = .failed
                save()
                return
            }
        }
    }

    private func handleReceipt(from: JID?, messageID: String) {
        guard let from else { return }
        for peer in peerCandidates(from) {
            let conversationID = StoredConversation.id(account: jid, peer: peer)
            if let record = findMessage(conversationID: conversationID, stanzaID: messageID), record.outgoing {
                record.state = .delivered
                save()
                return
            }
        }
    }

    /// The conversations a sender could belong to: a chat, or a room private message.
    private func peerCandidates(_ from: JID) -> [String] {
        let bare = Address.bare(from.stringValue)
        guard let resource = from.resource else { return [bare] }
        return [bare, "\(bare)/\(resource)"]
    }

    private func insert(peer: String, kind: ConversationKind, title: String, sender: String, body: String, timestamp: Date,
                        outgoing: Bool, key: String, stanzaID: String?, countsAsUnread: Bool) {
        let conversation = conversationRecord(peer: peer, kind: kind, title: title)
        let conversationID = conversation.id
        var existing = FetchDescriptor<StoredMessage>(predicate: #Predicate<StoredMessage> { $0.conversationID == conversationID && $0.dedupeKey == key })
        existing.fetchLimit = 1
        if let duplicate = (try? store.fetch(existing))?.first {
            // Our own message reflected back by a room means it got there.
            if duplicate.outgoing && duplicate.state != .delivered {
                duplicate.state = .delivered
                save()
            }
            return
        }
        store.insert(StoredMessage(conversationID: conversationID, dedupeKey: key, stanzaID: stanzaID, sender: sender, body: body,
                                   timestamp: timestamp, outgoing: outgoing, state: outgoing ? .sent : .received))
        if !outgoing && countsAsUnread && activeConversationID() != conversationID {
            conversation.unread += 1
        }
        touch(conversation, body: body, timestamp: timestamp)
    }

    // MARK: Archive

    private func syncArchiveIfNeeded() {
        guard archiveSyncPending, !archiveSyncRunning, !mamModule.availableVersions.isEmpty else { return }
        archiveSyncPending = false
        archiveSyncRunning = true
        let started = Date()
        // Overlap slightly: duplicates are dropped, gaps wouldn't be noticed.
        let from = account()?.lastArchiveSync?.addingTimeInterval(-300) ?? started.addingTimeInterval(-7 * 24 * 3600)
        fetchArchivePage(from: from, after: nil, page: 0, started: started)
    }

    private func fetchArchivePage(from: Date, after: String?, page: Int, started: Date) {
        let queryID = UUID().uuidString
        archiveQueryIDs.insert(queryID)
        mamModule.queryItems(start: from, queryId: queryID, rsm: RSM.Query(after: after, max: 100), completionHandler: { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finishedArchivePage(result, queryID: queryID, from: from, page: page, started: started)
            }
        })
    }

    private func finishedArchivePage(_ result: Result<MessageArchiveManagementModule.QueryResult, XMPPError>, queryID: String, from: Date, page: Int, started: Date) {
        switch result {
        case .success(let queryResult):
            if !queryResult.complete, let last = queryResult.rsm?.last, page < 20 {
                fetchArchivePage(from: from, after: last, page: page + 1, started: started)
            } else {
                account()?.lastArchiveSync = started
                save()
                archiveSyncRunning = false
            }
        case .failure:
            // Position stays put, so the next connect covers this range again.
            archiveSyncRunning = false
        }
    }

    // MARK: Rooms

    func joinRoom(address: String, nickname: String, password: String?) {
        let key = StoredRoom.key(account: jid, room: address)
        var existing = FetchDescriptor<StoredRoom>(predicate: #Predicate<StoredRoom> { $0.key == key })
        existing.fetchLimit = 1
        if let room = (try? store.fetch(existing))?.first {
            room.nickname = nickname
        } else {
            store.insert(StoredRoom(account: jid, room: address, nickname: nickname))
        }
        let passwordKey = Keychain.roomKey(account: jid, room: address)
        if let password, !password.isEmpty {
            Keychain.set(password, for: passwordKey)
        } else {
            Keychain.delete(passwordKey)
        }
        save()
        knownRooms.insert(address)
        _ = conversationRecord(peer: address, kind: .room, title: BareJID(address).localPart ?? address)
        invites.removeAll { $0.room == address }
        if client.state == .connected() {
            join(room: address, nickname: nickname, password: password, history: .initial)
        }
    }

    func leaveRoom(_ address: String) {
        if let room = mucModule.roomManager.room(for: client, with: BareJID(address)) {
            mucModule.leave(room: room)
        }
        for room in storedRooms() where room.room == address {
            store.delete(room)
        }
        Keychain.delete(Keychain.roomKey(account: jid, room: address))
        knownRooms.remove(address)
        roomStatus[address] = nil
        occupants[address] = nil
        roomCancellables[address] = nil
        save()
    }

    func declineInvite(_ invite: RoomInvite) {
        invites.removeAll { $0 == invite }
    }

    private func addInvite(room: String, inviter: String?, password: String?) {
        guard !knownRooms.contains(room), !invites.contains(where: { $0.room == room }) else { return }
        invites.append(RoomInvite(room: room, inviter: inviter, password: password))
    }

    private func rejoinRooms() {
        for room in storedRooms() {
            let id = StoredConversation.id(account: jid, peer: room.room)
            var fetch = FetchDescriptor<StoredConversation>(predicate: #Predicate<StoredConversation> { $0.id == id })
            fetch.fetchLimit = 1
            var history = RoomHistoryFetch.initial
            if let last = (try? store.fetch(fetch))?.first?.lastTimestamp, last > .distantPast {
                history = .from(last)
            }
            join(room: room.room, nickname: room.nickname,
                 password: Keychain.get(Keychain.roomKey(account: jid, room: room.room)), history: history)
        }
    }

    private func join(room address: String, nickname: String, password: String?, history: RoomHistoryFetch) {
        let bare = BareJID(address)
        guard let room = mucModule.roomManager.createRoom(for: client, with: bare, nickname: nickname, password: password) else {
            roomStatus[address] = .failed("Could not create the room.")
            return
        }
        // After a non-resumed reconnect the server has forgotten us, whatever
        // the local object still says.
        room.update(state: .not_joined())
        roomStatus[address] = .joining
        roomCancellables[address] = room.occupantsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in
                self?.occupants[address] = list.map(\.nickname).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
        mucModule.join(room: room, fetchHistory: history, completionHandler: { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finishedJoining(address, result: result)
            }
        })
    }

    private func finishedJoining(_ address: String, result: Result<RoomJoinResult, XMPPError>) {
        switch result {
        case .success(.joined):
            roomStatus[address] = .joined
        case .success(.created):
            // New rooms stay locked until configured; accept the server defaults.
            roomStatus[address] = .joined
            let roomJID = JID(BareJID(address))
            let muc = mucModule
            muc.getRoomConfiguration(roomJid: roomJID, completionHandler: { result in
                if case .success(let form) = result {
                    muc.setRoomConfiguration(roomJid: roomJID, configuration: form, completionHandler: { _ in })
                }
            })
        case .failure(let error):
            roomStatus[address] = .failed(error.localizedDescription)
        }
    }

    // MARK: Storage helpers

    private func account() -> StoredAccount? {
        let jid = self.jid
        var fetch = FetchDescriptor<StoredAccount>(predicate: #Predicate<StoredAccount> { $0.jid == jid })
        fetch.fetchLimit = 1
        return (try? store.fetch(fetch))?.first
    }

    private func storedRooms() -> [StoredRoom] {
        let jid = self.jid
        return (try? store.fetch(FetchDescriptor<StoredRoom>(predicate: #Predicate<StoredRoom> { $0.account == jid }))) ?? []
    }

    private func rosterName(_ bare: String) -> String? {
        rosterModule.rosterManager.item(for: client, jid: JID(bare))?.name
    }

    private func findMessage(conversationID: String, stanzaID: String) -> StoredMessage? {
        let wanted: String? = stanzaID
        var fetch = FetchDescriptor<StoredMessage>(predicate: #Predicate<StoredMessage> { $0.conversationID == conversationID && $0.stanzaID == wanted })
        fetch.fetchLimit = 1
        return (try? store.fetch(fetch))?.first
    }

    private func conversationRecord(peer: String, kind: ConversationKind, title: String) -> StoredConversation {
        let id = StoredConversation.id(account: jid, peer: peer)
        var fetch = FetchDescriptor<StoredConversation>(predicate: #Predicate<StoredConversation> { $0.id == id })
        fetch.fetchLimit = 1
        if let existing = (try? store.fetch(fetch))?.first { return existing }
        let created = StoredConversation(account: jid, peer: peer, kind: kind, title: title)
        store.insert(created)
        return created
    }

    private func touch(_ conversation: StoredConversation, body: String, timestamp: Date) {
        if timestamp >= conversation.lastTimestamp {
            conversation.lastTimestamp = timestamp
            conversation.lastBody = body
        }
        save()
    }

    private func save() {
        do {
            try store.save()
        } catch {
            print("RoostChat: could not save: \(error)")
        }
    }
}
