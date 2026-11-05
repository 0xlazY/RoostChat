import Combine
import Foundation
import Network
import RoostChatCore
import SwiftData
import UIKit

/// Connection settings the user edits for an account.
struct AccountConnectionSettings {
    var host = ""
    var port = ""
    var directTLS = false
    var resource = ""
    var allowUnverifiedTLS = false

    /// False when a custom host or port was typed that can't be used.
    var isValid: Bool {
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            return port.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return ServerAddress.parse(host: host, port: port, directTLS: directTLS) != nil
    }
}

/// All configured accounts, plus the app-wide state Pidgin keeps globally: one
/// status applied to every account.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [AccountSession] = []
    @Published private(set) var availability: Availability = .available
    @Published private(set) var statusMessage: String = ""
    /// A conversation to open, from tapping a notification.
    @Published var pendingRoute: ChatRoute?
    @Published private(set) var pushProblem: String?
    private var pushToken: String?

    /// The conversation on screen, which doesn't accumulate unread messages.
    var activeRoute: ChatRoute?

    let notifier = Notifier()
    #if SILENT_AUDIO
    private let keeper = BackgroundKeeper()
    #endif
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
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
        AppSettings.registerDefaults()
        let defaults = UserDefaults.standard
        availability = defaults.string(forKey: Self.availabilityKey).flatMap(Availability.init(rawValue:)) ?? .available
        statusMessage = defaults.string(forKey: Self.messageKey) ?? ""
        AppDelegate.onToken = { [weak self] token in
            Task { @MainActor [weak self] in
                self?.received(pushToken: token)
            }
        }
        AppDelegate.onTokenError = { [weak self] problem in
            Task { @MainActor [weak self] in
                self?.pushProblem = "This build can't use push: \(problem)"
                DebugLog.shared.add(.app, "Push registration failed: \(problem)")
            }
        }
        notifier.onOpen = { [weak self] route in
            Task { @MainActor [weak self] in
                self?.pendingRoute = route
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        DebugLog.shared.add(.app, "App started")
        let accounts = (try? store.fetch(FetchDescriptor<StoredAccount>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        for account in accounts {
            let session = makeSession(jid: account.jid)
            if account.enabled { session.connect() }
        }
        if UserDefaults.standard.bool(forKey: AppSettings.notificationsEnabled) {
            notifier.requestAuthorization()
        }
        registerForPushIfConfigured()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.networkChanged(satisfied: satisfied)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "roostchat.network"))
        updateKeepAlive()
        updateBadge()
    }

    // MARK: Push

    var pushRelay: String? {
        UserDefaults.standard.string(forKey: AppSettings.pushRelay).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Saves the relay domain, or clears it when blank. False if it isn't valid.
    func setPushRelay(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: AppSettings.pushRelay)
        } else if let domain = PushRelay.normalizedDomain(trimmed) {
            UserDefaults.standard.set(domain, forKey: AppSettings.pushRelay)
        } else {
            return false
        }
        applyPushSettings()
        registerForPushIfConfigured()
        return true
    }

    private func registerForPushIfConfigured() {
        #if PUSH_NOTIFICATIONS
        guard pushRelay != nil, pushToken == nil else { return }
        pushProblem = nil
        notifier.requestAuthorization()
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    private func received(pushToken token: Data) {
        pushToken = PushRelay.hexToken(token)
        pushProblem = nil
        DebugLog.shared.add(.app, "Received a push token")
        applyPushSettings()
    }

    private func applyPushSettings() {
        for session in sessions {
            session.pushRelay = pushRelay
            session.pushToken = pushToken
            session.updatePush()
        }
    }

    /// A contact's roster entry, for showing their status. Nil for rooms and for
    /// people who aren't in the buddy list, whose status isn't known.
    func buddy(account: String, jid: String) -> Buddy? {
        session(for: account)?.buddies.first { $0.jid == jid }
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

    func addAccount(jid: String, password: String, settings: AccountConnectionSettings) -> String? {
        guard account(jid) == nil else { return "That account already exists." }
        guard Keychain.set(password, for: Keychain.accountKey(jid)) else {
            return "Could not save the password to the Keychain."
        }
        let stored = StoredAccount(jid: jid)
        store.insert(stored)
        apply(settings, to: stored)
        try? store.save()
        makeSession(jid: jid).connect()
        updateKeepAlive()
        return nil
    }

    func connectionSettings(for jid: String) -> AccountConnectionSettings {
        guard let stored = account(jid) else { return AccountConnectionSettings() }
        return AccountConnectionSettings(host: stored.serverHost ?? "",
                                         port: stored.serverPort.map(String.init) ?? "",
                                         directTLS: stored.useDirectTLS,
                                         resource: stored.resource ?? "",
                                         allowUnverifiedTLS: stored.allowUnverifiedTLS)
    }

    func saveConnectionSettings(_ settings: AccountConnectionSettings, jid: String) {
        guard let stored = account(jid) else { return }
        apply(settings, to: stored)
        try? store.save()
        session(for: jid)?.reconnect()
        updateKeepAlive()
    }

    private func apply(_ settings: AccountConnectionSettings, to stored: StoredAccount) {
        if let server = ServerAddress.parse(host: settings.host, port: settings.port, directTLS: settings.directTLS) {
            stored.serverHost = server.host
            stored.serverPort = server.port
            stored.useDirectTLS = settings.directTLS
        } else {
            stored.serverHost = nil
            stored.serverPort = nil
            stored.useDirectTLS = false
        }
        let resource = settings.resource.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.resource = resource.isEmpty ? nil : resource
        stored.allowUnverifiedTLS = settings.allowUnverifiedTLS
        if !settings.allowUnverifiedTLS { stored.pinnedCertificate = nil }
    }

    func forgetPinnedCertificate(jid: String) {
        account(jid)?.pinnedCertificate = nil
        try? store.save()
        DebugLog.shared.add(.connection, account: jid, "Forgot the accepted certificate")
    }

    func updatePassword(jid: String, password: String) {
        Keychain.set(password, for: Keychain.accountKey(jid))
        session(for: jid)?.reconnect()
        updateKeepAlive()
    }

    func setConnectOnLaunch(_ value: Bool, jid: String) {
        account(jid)?.enabled = value
        try? store.save()
    }

    func connect(jid: String) {
        session(for: jid)?.connect()
        updateKeepAlive()
    }

    func disconnect(jid: String) {
        session(for: jid)?.disconnect()
        updateKeepAlive()
    }

    /// Removes the account and everything stored for it on this device. Nothing
    /// on the server is touched.
    func removeAccount(jid: String) {
        session(for: jid)?.disablePush()
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
        updateKeepAlive()
        updateBadge()
    }

    func deleteConversation(_ conversation: StoredConversation) {
        if conversation.kind == .room {
            session(for: conversation.account)?.leaveRoom(conversation.peer)
        }
        deleteMessages(conversationID: conversation.id)
        store.delete(conversation)
        try? store.save()
        updateBadge()
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
            updateBadge()
        }
    }

    // MARK: Status

    /// The status only ever changes here, by the user's choice. Nothing in the app
    /// lowers it on backgrounding or idling.
    func setStatus(_ availability: Availability, message: String) {
        self.availability = availability
        statusMessage = message
        UserDefaults.standard.set(availability.rawValue, forKey: Self.availabilityKey)
        UserDefaults.standard.set(message, forKey: Self.messageKey)
        for session in sessions {
            session.setPresence(availability, message: message)
        }
    }

    // MARK: Notifications

    private func handleIncoming(_ notice: IncomingNotice) {
        updateBadge()
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppSettings.notificationsEnabled) else { return }
        if inForeground && activeRoute?.id == notice.route.id { return }
        let mode = defaults.string(forKey: AppSettings.notificationRooms).flatMap(RoomNotificationMode.init(rawValue:)) ?? .mentions
        guard NotificationPolicy.shouldNotify(isRoom: notice.route.kind == .room, mode: mode, body: notice.body, ownNickname: notice.ownNickname) else { return }
        notifier.post(route: notice.route, sender: notice.sender, body: notice.body,
                      showPreview: defaults.bool(forKey: AppSettings.notificationPreview))
    }

    private func updateBadge() {
        let conversations = (try? store.fetch(FetchDescriptor<StoredConversation>())) ?? []
        notifier.setBadge(conversations.reduce(0) { $0 + $1.unread })
    }

    // MARK: App lifecycle

    func enterForeground() {
        inForeground = true
        endBackgroundTask()
        guard started else { return }
        DebugLog.shared.add(.app, "Entered foreground")
        for session in sessions where session.userWantsConnection {
            session.connect()
            session.checkConnection()
        }
        if let route = activeRoute {
            markRead(account: route.account, peer: route.peer)
        }
        updateKeepAlive()
    }

    /// iOS allows a short grace period before suspending the app, during which
    /// messages still arrive. After that the socket can't stay open, so it closes
    /// deliberately and the server holds the session, keeping the status contacts
    /// see, until its own time limit. The status itself is never changed.
    func enterBackground() {
        inForeground = false
        DebugLog.shared.add(.app, "Entered background (silent audio \(keepAliveRunning ? "running" : "off"))")
        // With the optional silent audio running, iOS doesn't suspend the app.
        guard !keepAliveRunning else { return }
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Keep XMPP connection") { [weak self] in
            self?.finishBackgroundTime()
        }
        if backgroundTask == .invalid { finishBackgroundTime() }
    }

    private func finishBackgroundTime() {
        if !inForeground {
            DebugLog.shared.add(.app, "Background time ended, closing connections")
            for session in sessions {
                session.suspend()
            }
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// The audio session must start while the app is in the foreground, so this
    /// runs at launch and on return rather than on backgrounding.
    func updateKeepAlive() {
        #if SILENT_AUDIO
        let wanted = UserDefaults.standard.bool(forKey: AppSettings.keepAlive) && sessions.contains { $0.userWantsConnection }
        if wanted {
            keeper.start()
        } else {
            keeper.stop()
        }
        #endif
    }

    var keepAliveRunning: Bool {
        #if SILENT_AUDIO
        return keeper.isRunning
        #else
        return false
        #endif
    }

    private func networkChanged(satisfied: Bool) {
        DebugLog.shared.add(.app, "Network \(satisfied ? "available" : "unavailable")")
        guard satisfied else {
            networkWasUnavailable = true
            return
        }
        let returned = networkWasUnavailable
        networkWasUnavailable = false
        guard inForeground || keepAliveRunning || backgroundTask != .invalid else { return }
        for session in sessions {
            if returned {
                session.networkBecameAvailable()
            } else {
                // Same connectivity, possibly a new interface: is the socket alive?
                session.checkConnection()
            }
        }
    }

    @discardableResult
    private func makeSession(jid: String) -> AccountSession {
        let session = AccountSession(jid: jid, store: store)
        session.activeConversationID = { [weak self] in
            guard let self, self.inForeground else { return nil }
            return self.activeRoute?.id
        }
        session.onIncoming = { [weak self] notice in self?.handleIncoming(notice) }
        session.pushRelay = pushRelay
        session.pushToken = pushToken
        session.setPresence(availability, message: statusMessage)
        // Views observe only the manager, so forward each account's changes.
        sessionObservers[jid] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessions.append(session)
        return session
    }
}
