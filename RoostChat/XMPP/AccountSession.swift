import Combine
import Foundation
import Martin
import RoostChatCore
import SwiftData

enum Availability: String, CaseIterable, Identifiable {
    case chat, available, away, xa, dnd, offline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: return "Free for Chat"
        case .available: return "Available"
        case .away: return "Away"
        case .xa: return "Extended Away"
        case .dnd: return "Do Not Disturb"
        case .offline: return "Offline"
        }
    }

    fileprivate init(show: Presence.Show?) {
        switch show {
        case .chat: self = .chat
        case .online: self = .available
        case .away: self = .away
        case .xa: self = .xa
        case .dnd: self = .dnd
        case .none: self = .offline
        }
    }

    fileprivate var show: Presence.Show {
        switch self {
        case .chat: return .chat
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

/// A message worth telling the user about.
struct IncomingNotice {
    let route: ChatRoute
    let sender: String
    let body: String
    /// The account's nickname in the room, for detecting mentions.
    let ownNickname: String?
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
    @Published private(set) var diagnostics = ConnectionDiagnostics()
    @Published private(set) var capabilities = ServerCapabilities()
    /// The resource the server bound this connection to.
    @Published private(set) var assignedResource: String?

    /// Whichever conversation is on screen; it doesn't accumulate unread messages.
    var activeConversationID: () -> String? = { nil }
    var onIncoming: ((IncomingNotice) -> Void)?
    /// Whether the user wants this account online. Survives the app being backgrounded.
    private(set) var userWantsConnection = false

    private let client: XMPPClient
    private let store: ModelContext
    private let rosterModule: RosterModule
    private let presenceModule: PresenceModule
    private let mucModule: MucModule
    private let mamModule: MessageArchiveManagementModule
    private let carbonsModule: MessageCarbonsModule
    private let pingModule: PingModule
    private let streamManagement: StreamManagementModule
    private let streamLogger: StreamDebugLogger
    private var watchdog: Task<Void, Never>?
    private var pingInFlight = false
    private var typingExpiry = [String: Task<Void, Never>]()
    /// A contact whose client stops responding never sends "paused", so "typing"
    /// clears itself after this long.
    private static let typingTimeout: UInt64 = 30_000_000_000
    private let avatarModule: PEPUserAvatarModule
    private let vcardModule: VCardTempModule
    private let pushModule: PushNotificationsModule
    /// The relay and token last enabled on the server, for turning them off.
    private var enabledPush: (relay: String, token: String)?
    private var avatarQueue: [String] = []
    private var avatarsRequested = Set<String>()
    private var avatarFetchesActive = 0

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
        let streamFeaturesModule = modules.register(StreamFeaturesModule())
        let authModule = modules.register(TLSRequiredAuthModule())
        modules.register(SaslModule())
        modules.register(ResourceBinderModule())
        modules.register(SessionEstablishmentModule())
        let discovery = modules.register(DiscoveryModule(identity: DiscoveryModule.Identity(category: "client", type: "phone", name: "RoosterChat")))
        modules.register(SoftwareVersionModule(version: SoftwareVersionModule.SoftwareVersion(name: "RoosterChat", version: "0.2", os: nil)))
        pingModule = modules.register(PingModule())
        rosterModule = modules.register(RosterModule(rosterManager: RosterManagerBase<AppRosterStore>(store: AppRosterStore())))
        presenceModule = modules.register(PresenceModule())
        modules.register(CapabilitiesModule())
        let messageModule = modules.register(ChatStateMessageModule(chatManager: DefaultChatManager(store: DefaultChatStore())))
        let verifiedCarbons = modules.register(VerifiedCarbonsModule())
        carbonsModule = verifiedCarbons
        mamModule = modules.register(MessageArchiveManagementModule())
        mucModule = modules.register(MucModule(roomManager: RoomManagerBase<AppRoomStore>(store: AppRoomStore())))
        modules.register(PubSubModule())
        avatarModule = modules.register(PEPUserAvatarModule())
        vcardModule = modules.register(VCardTempModule())
        pushModule = modules.register(PushNotificationsModule())
        let streamManagementModule = modules.register(StreamManagementModule())
        // Ask the server to hold the session (and our status) while the socket
        // is down. Servers cap this at their own limit.
        streamManagementModule.maxResumptionTimeout = 3600
        streamManagement = streamManagementModule
        let receipts = modules.register(MessageDeliveryReceiptsModule())
        modules.register(ChatStateNotificationsModule())

        client.connectionConfiguration.userJid = BareJID(jid)

        let logger = StreamDebugLogger(account: jid)
        streamLogger = logger
        client.streamLogger = logger

        knownRooms = Set(storedRooms().map(\.room))

        // These two fire on Martin's queues, so they must not touch actor state.
        let refresh = rosterRefresh

        client.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handle(state: state) }
            .store(in: &cancellables)

        messageModule.chatStates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.handleChatState(message) }
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

        // Martin's disconnect after a failed login may not carry the reason, so
        // watch for it here. A retry could get the account locked.
        authModule.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .error(let error) = state { self?.authenticationFailed(error) }
            }
            .store(in: &cancellables)

        discovery.$serverDiscoResult
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                self?.capabilities.serverFeatures = result.features.sorted()
                self?.capabilities.identities = result.identities.map { identity in
                    "\(identity.category)/\(identity.type)" + (identity.name.map { " (\($0))" } ?? "")
                }
            }
            .store(in: &cancellables)

        discovery.$accountDiscoResult
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in self?.capabilities.accountFeatures = result.features.sorted() }
            .store(in: &cancellables)

        streamFeaturesModule.$streamFeatures
            .receive(on: DispatchQueue.main)
            .sink { [weak self] features in self?.noteStreamFeatures(features) }
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

        presenceModule.presencePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in self?.noteAvatarHash(in: change.presence, from: change.jid) }
            .store(in: &cancellables)

        avatarModule.avatarChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in self?.handleAvatarChange(jid: change.jid, ids: change.info.map(\.id), largest: change.info.map(\.size).max()) }
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
        userWantsConnection = true
        wantsConnection = true
        reconnectTask?.cancel()
        reconnectTask = nil
        diagnostics.nextRetry = nil
        guard case .disconnected = client.state else { return }
        guard let account = account() else { return }
        guard let password = Keychain.get(Keychain.accountKey(jid)) else {
            fail("Password missing. Enter it in this account's settings.")
            userWantsConnection = false
            wantsConnection = false
            return
        }
        applySettings(account, password: password)
        diagnostics.attempts += 1
        diagnostics.lastAttempt = Date()
        diagnostics.tlsSummary = nil
        diagnostics.tlsFingerprint = nil
        diagnostics.tlsSubject = nil
        capabilities.saslMechanisms = []
        capabilities.streamFeatures = []
        status = .connecting
        log("Connecting (attempt \(diagnostics.attempts))")
        client.login()
    }

    private func applySettings(_ account: StoredAccount, password: String) {
        let accountJID = jid
        let domain = BareJID(jid).domain
        client.connectionConfiguration.resource = account.resource
        client.connectionConfiguration.credentials = .password(password: password, authenticationName: nil, cache: nil)

        let validator = makeTLSValidator(domain: domain, allowUnverified: account.allowUnverifiedTLS, pinned: account.pinnedCertificate) { [weak self] observation, decision in
            Task { @MainActor [weak self] in
                self?.recordTLS(observation, decision: decision)
            }
        }
        let resolver: DNSSrvResolver
        if let host = account.serverHost {
            let port = account.serverPort ?? (account.useDirectTLS ? 5223 : 5222)
            resolver = FixedServerResolver(account: accountJID, host: host, port: port, directTLS: account.useDirectTLS)
            diagnostics.serverRoute = "\(host):\(port) (custom, \(account.useDirectTLS ? "direct TLS" : "STARTTLS"))"
        } else {
            resolver = LoggingDNSResolver(account: accountJID) { [weak self] summary in
                Task { @MainActor [weak self] in
                    self?.diagnostics.serverRoute = summary
                }
            }
            diagnostics.serverRoute = "Looking up DNS records for \(domain)"
        }
        client.connectionConfiguration.modifyConnectorOptions(type: SocketConnector.Options.self) { options in
            options.sslCertificateValidation = .customValidator(validator)
            options.conntectionTimeout = 30
            options.dnsResolver = resolver
        }
    }

    private func recordTLS(_ observation: TLSObservation, decision: TLSDecision) {
        diagnostics.tlsFingerprint = observation.fingerprint
        diagnostics.tlsSubject = observation.subject
        switch decision {
        case .acceptVerified:
            diagnostics.tlsSummary = "Verified by the system"
        case .acceptPinned:
            diagnostics.tlsSummary = "Unverified, matches the accepted certificate"
        case .acceptAndPin:
            diagnostics.tlsSummary = "Unverified, accepted on first use and pinned"
            account()?.pinnedCertificate = observation.fingerprint
            save()
        case .rejectUnverified:
            diagnostics.tlsSummary = "Rejected: \(observation.systemError ?? "not trusted")"
        case .rejectChanged(let pinned):
            diagnostics.tlsSummary = "Rejected: certificate changed. Accepted \(pinned), server presented \(observation.fingerprint ?? "unknown")"
        }
        log("TLS: \(diagnostics.tlsSummary ?? "")")
    }

    /// Closes the socket without ending the XMPP session, so that if the server
    /// supports stream management the next connect resumes where this left off.
    func suspend() {
        stop(force: true)
    }

    func disconnect() {
        userWantsConnection = false
        stop(force: false)
    }

    /// Applies changed settings by dropping the session and connecting afresh.
    func reconnect() {
        userWantsConnection = true
        reconnectAttempt = 0
        if case .disconnected = client.state {
            connect()
            return
        }
        wantsConnection = true
        Task { [client] in
            try? await client.disconnect(force: false)
        }
    }

    private func stop(force: Bool) {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        diagnostics.nextRetry = nil
        Task { [client] in
            try? await client.disconnect(force: force)
        }
    }

    /// Network came back: don't wait out the backoff timer.
    func networkBecameAvailable() {
        guard wantsConnection else { return }
        reconnectAttempt = 0
        if case .disconnected = client.state {
            connect()
        } else {
            checkConnection()
        }
    }

    /// Sockets can die silently, for example when moving between networks. A ping
    /// that times out forces a reconnect, which resumes the stream when possible.
    func checkConnection() {
        guard client.state == .connected(), !pingInFlight else { return }
        pingInFlight = true
        pingModule.ping(JID(BareJID(jid)), timeout: 20, completionHandler: { [weak self] result in
            var timedOut = false
            if case .failure(.remote_server_timeout) = result { timedOut = true }
            let didTimeOut = timedOut
            Task { @MainActor [weak self] in
                self?.finishedWatchdogPing(timedOut: didTimeOut)
            }
        })
    }

    private func finishedWatchdogPing(timedOut: Bool) {
        pingInFlight = false
        guard timedOut, wantsConnection else { return }
        log("Server stopped responding, reconnecting")
        Task { [client] in
            try? await client.disconnect(force: true)
        }
    }

    /// Measures the round trip to the server, for the diagnostics screen.
    func measurePing() {
        guard client.state == .connected() else {
            diagnostics.lastPing = "Not connected"
            return
        }
        diagnostics.lastPing = "Pinging…"
        let started = Date()
        pingModule.ping(JID(BareJID(jid)), timeout: 20, completionHandler: { [weak self] result in
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let text: String
            switch result {
            case .success: text = "\(elapsed) ms"
            case .failure(let error): text = "Failed: \(error.rawValue)"
            }
            Task { @MainActor [weak self] in
                self?.diagnostics.lastPing = text
            }
        })
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                self?.checkConnection()
            }
        }
    }

    private func handle(state: XMPPClient.State) {
        // The publisher replays the initial state before anything has happened.
        guard diagnostics.lastAttempt != nil else { return }
        diagnostics.lastStateChange = Date()
        switch state {
        case .connecting:
            status = .connecting
        case .connected(let resumed):
            status = .online
            reconnectAttempt = 0
            diagnostics.connectedSince = Date()
            diagnostics.lastError = nil
            diagnostics.lastErrorAt = nil
            diagnostics.boundJID = client.boundJid?.stringValue ?? diagnostics.boundJID
            assignedResource = client.boundJid?.resource ?? assignedResource
            diagnostics.resumed = resumed
            diagnostics.tlsActive = client.connector?.activeFeatures.contains(.TLS) ?? false
            log(resumed ? "Connected, stream resumed" : "Connected as \(diagnostics.boundJID ?? jid)")
            startWatchdog()
            if !resumed {
                avatarsRequested = []
                avatarQueue = []
                requestAvatar(jid)
                carbonsModule.enable(nil)
                enabledPush = nil
                updatePush()
                rejoinRooms()
                archiveSyncPending = true
                syncArchiveIfNeeded()
            }
        case .disconnecting:
            break
        case .disconnected(let reason):
            watchdog?.cancel()
            watchdog = nil
            pingInFlight = false
            diagnostics.connectedSince = nil
            assignedResource = nil
            typingExpiry.values.forEach { $0.cancel() }
            typingExpiry = [:]
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
        case .authenticationFailure(let error):
            authenticationFailed(error)
        case .sslCertError:
            // Not retried: this may be an interception attempt.
            userWantsConnection = false
            wantsConnection = false
            fail("TLS certificate not accepted. \(diagnostics.tlsSummary ?? "")")
        case .none:
            log("Disconnected")
            if wantsConnection {
                scheduleReconnect()
            } else if case .failed = status {
                // Keep showing why the connection ended.
            } else {
                status = .offline
            }
        case .timeout:
            connectionLost("Timed out connecting to the server")
        case .noRouteToServer:
            connectionLost("Could not reach the server")
        case .xmlError(let detail):
            connectionLost("Invalid XML from the server: \(detail ?? "unknown")")
        case .streamError(let element):
            connectionLost("Stream error from the server: \(element.description)")
        }
    }

    private func authenticationFailed(_ error: Error) {
        userWantsConnection = false
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        diagnostics.nextRetry = nil
        fail("Login failed: \(error.localizedDescription)")
    }

    private func connectionLost(_ reason: String) {
        if wantsConnection {
            fail(reason)
            scheduleReconnect()
        } else {
            log(reason)
            status = .offline
        }
    }

    private func fail(_ reason: String) {
        status = .failed(reason)
        diagnostics.lastError = reason
        diagnostics.lastErrorAt = Date()
        DebugLog.shared.add(.connection, account: jid, "Error: \(reason)")
    }

    private func log(_ text: String) {
        DebugLog.shared.add(.connection, account: jid, text)
    }

    private func scheduleReconnect() {
        let delay = Reconnect.delay(attempt: reconnectAttempt, jitter: Double.random(in: 0...1))
        reconnectAttempt += 1
        diagnostics.nextRetry = Date().addingTimeInterval(delay)
        log("Retrying in \(Int(delay)) s")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func noteStreamFeatures(_ features: StreamFeatures) {
        guard let element = features.element else { return }
        for child in element.getChildren() {
            let label = child.xmlns.map { "\(child.name) (\($0))" } ?? child.name
            if !capabilities.streamFeatures.contains(label) {
                capabilities.streamFeatures.append(label)
            }
            if child.name == "mechanisms" {
                capabilities.saslMechanisms = child.getChildren(name: "mechanism").compactMap(\.value)
            }
        }
        diagnostics.smEnabled = streamManagement.resumptionEnabled
    }

    // MARK: Push

    var pushToken: String?
    var pushRelay: String?

    /// Asks the XMPP server to notify the relay while this account's connection is
    /// down (XEP-0357). The server stores the relay address and device token; no
    /// server configuration is needed if it already offers push.
    func updatePush() {
        guard client.state == .connected() else { return }
        guard let relay = pushRelay, let token = pushToken else {
            disablePush()
            if pushRelay == nil { diagnostics.pushStatus = nil }
            return
        }
        if let current = enabledPush, current.relay == relay, current.token == token { return }
        disablePush()
        diagnostics.pushStatus = "Enabling through \(relay)…"
        pushModule.enable(serviceJid: JID(relay), node: token, completionHandler: { [weak self] result in
            var failure: String?
            if case .failure(let error) = result { failure = error.localizedDescription }
            let problem = failure
            Task { @MainActor [weak self] in
                self?.finishedEnablingPush(relay: relay, token: token, problem: problem)
            }
        })
    }

    private func finishedEnablingPush(relay: String, token: String, problem: String?) {
        if let problem {
            diagnostics.pushStatus = "Server refused: \(problem)"
            log("Push not enabled: \(problem)")
        } else {
            enabledPush = (relay, token)
            diagnostics.pushStatus = "Enabled through \(relay)"
            log("Push enabled through \(relay)")
        }
    }

    /// Stops pushes for this device, for instance before removing the account.
    func disablePush() {
        guard let current = enabledPush else { return }
        enabledPush = nil
        guard client.state == .connected() else { return }
        pushModule.disable(serviceJid: JID(current.relay), node: current.token, completionHandler: nil)
    }

    // MARK: Avatars

    /// Queues a fetch of `key`, a bare JID or `room/nick`, once per connection.
    private func requestAvatar(_ key: String) {
        guard avatarsRequested.insert(key).inserted else { return }
        avatarQueue.append(key)
        pumpAvatarQueue()
    }

    private func pumpAvatarQueue() {
        while avatarFetchesActive < 3, !avatarQueue.isEmpty, client.state == .connected() {
            let key = avatarQueue.removeFirst()
            avatarFetchesActive += 1
            if Address.resource(key) == nil {
                fetchPEPAvatar(key)
            } else {
                fetchVCardAvatar(key)
            }
        }
    }

    private func finishAvatarFetch() {
        avatarFetchesActive -= 1
        pumpAvatarQueue()
    }

    /// XEP-0084, falling back to vCard for contacts who don't publish there.
    private func fetchPEPAvatar(_ key: String) {
        let bare = BareJID(key)
        avatarModule.retrieveAvatarMetadata(from: bare, itemId: nil, fireEvents: false, completionHandler: { [weak self] result in
            var itemID: String?
            var size = 0
            if case .success(let info) = result {
                itemID = info.id
                size = info.size
            }
            let foundID = itemID
            let foundSize = size
            Task { @MainActor [weak self] in
                self?.finishedAvatarMetadata(key, itemID: foundID, size: foundSize)
            }
        })
    }

    private func finishedAvatarMetadata(_ key: String, itemID: String?, size: Int) {
        guard let itemID else {
            fetchVCardAvatar(key)
            return
        }
        guard itemID != AvatarStore.shared.hash(for: key), size <= AvatarStore.maxBytes else {
            finishAvatarFetch()
            return
        }
        avatarModule.retrieveAvatar(from: BareJID(key), itemId: itemID, completionHandler: { [weak self] result in
            var picture: Data?
            if case .success(let item) = result { picture = item.1 }
            let data = picture
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data {
                    AvatarStore.shared.save(data, hash: itemID, for: key)
                    self.finishAvatarFetch()
                } else {
                    self.fetchVCardAvatar(key)
                }
            }
        })
    }

    /// XEP-0153. Only inline pictures are used: following a link in a vCard would
    /// reveal your IP address to whoever the contact points it at.
    private func fetchVCardAvatar(_ key: String) {
        vcardModule.retrieveVCard(from: JID(key), completionHandler: { [weak self] result in
            var picture: Data?
            if case .success(let vcard) = result, let encoded = vcard.photos.first?.binval, encoded.count <= AvatarStore.maxBytes * 2 {
                picture = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
            }
            let data = picture
            Task { @MainActor [weak self] in
                if let data { AvatarStore.shared.save(data, hash: nil, for: key) }
                self?.finishAvatarFetch()
            }
        })
    }

    /// Contacts and room occupants advertise a picture's hash in their presence.
    private func noteAvatarHash(in presence: Presence, from sender: JID) {
        guard let hash = presence.findChild(name: "x", xmlns: "vcard-temp:x:update")?.findChild(name: "photo")?.value,
              !hash.isEmpty else { return }
        let bare = Address.bare(sender.stringValue)
        let isRoom = knownRooms.contains(bare)
        guard !isRoom || sender.resource != nil else { return }
        let key = isRoom ? "\(bare)/\(sender.resource ?? "")" : bare
        guard hash != AvatarStore.shared.hash(for: key) else { return }
        avatarsRequested.remove(key)
        requestAvatar(key)
    }

    private func handleAvatarChange(jid sender: JID, ids: [String], largest: Int?) {
        let key = Address.bare(sender.stringValue)
        if ids.isEmpty {
            AvatarStore.shared.remove(key)
        } else if let first = ids.first, first != AvatarStore.shared.hash(for: key), (largest ?? 0) <= AvatarStore.maxBytes {
            avatarsRequested.remove(key)
            requestAvatar(key)
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
        if client.state == .connected() {
            for buddy in buddies { requestAvatar(buddy.jid) }
        }
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
        storeRouted(message, source: .live, timestamp: MessageRouting.effectiveTimestamp(delay: message.delay?.stamp))
    }

    private func handleChatState(_ message: Message) {
        guard let from = message.from, let state = message.chatState else { return }
        let peer = Address.bare(from.stringValue)
        guard peer != jid, !knownRooms.contains(peer) else { return }
        setTyping(state == .composing, peer: peer)
    }

    private func setTyping(_ typing: Bool, peer: String) {
        typingExpiry[peer]?.cancel()
        typingExpiry[peer] = nil
        guard typing else {
            typingPeers.remove(peer)
            return
        }
        typingPeers.insert(peer)
        typingExpiry[peer] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.typingTimeout)
            guard !Task.isCancelled else { return }
            self?.setTyping(false, peer: peer)
        }
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
                   timestamp: timestamp, outgoing: outgoing, key: key, stanzaID: message.id, countsAsUnread: countsAsUnread,
                   mediaURL: MediaLink.detect(oob: message.oob, body: body), ownNickname: nil)
            if !outgoing { setTyping(false, peer: peer) }
        case .roomPrivate(let peer, _, let nick, let outgoing):
            insert(peer: peer, kind: .roomPrivate, title: nick, sender: outgoing ? "me" : nick, body: body,
                   timestamp: timestamp, outgoing: outgoing, key: key, stanzaID: message.id, countsAsUnread: countsAsUnread,
                   mediaURL: MediaLink.detect(oob: message.oob, body: body), ownNickname: nil)
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
               key: key, stanzaID: message.id, countsAsUnread: stamp == nil,
               mediaURL: MediaLink.detect(oob: message.oob, body: body), ownNickname: room.nickname)
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
                        outgoing: Bool, key: String, stanzaID: String?, countsAsUnread: Bool, mediaURL: String?, ownNickname: String?) {
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
                                   timestamp: timestamp, outgoing: outgoing, state: outgoing ? .sent : .received, mediaURL: mediaURL))
        if !outgoing && countsAsUnread && activeConversationID() != conversationID {
            conversation.unread += 1
        }
        touch(conversation, body: body, timestamp: timestamp)
        if !outgoing && countsAsUnread {
            let route = ChatRoute(account: jid, peer: peer, kind: kind, title: conversation.title)
            onIncoming?(IncomingNotice(route: route, sender: sender, body: body, ownNickname: ownNickname))
        }
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
