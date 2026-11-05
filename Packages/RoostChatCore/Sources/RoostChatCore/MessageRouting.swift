import Foundation

/// How a stanza reached us. Determines which sender checks apply.
public enum MessageSource: Equatable {
    case live
    case carbonSent
    case carbonReceived
    case archive
}

/// Where a message with a body belongs.
public enum MessageRoute: Equatable {
    case ignore
    /// One-to-one conversation with a bare JID.
    case chat(peer: String, outgoing: Bool)
    /// Private message through a room. `peer` is the full `room/nick` JID, kept
    /// separate from the room so a reply can never be posted publicly.
    case roomPrivate(peer: String, room: String, nick: String, outgoing: Bool)
}

public struct MessageEnvelope: Equatable {
    public var from: String?
    public var to: String?
    public var type: String?
    public var body: String?

    public init(from: String?, to: String?, type: String?, body: String?) {
        self.from = from
        self.to = to
        self.type = type
        self.body = body
    }
}

public enum MessageRouting {
    /// Decides where a non-groupchat message goes.
    ///
    /// Callers must have already verified that carbons and archive results
    /// themselves came from the account's own server-side address; this adds
    /// the check on the *forwarded* message inside them.
    public static func route(_ message: MessageEnvelope,
                             source: MessageSource,
                             account: String,
                             knownRooms: Set<String>) -> MessageRoute {
        guard let body = message.body, !body.isEmpty else { return .ignore }
        // Error bounces often echo our own body; never show them as incoming.
        if message.type == "error" || message.type == "groupchat" { return .ignore }

        let accountBare = account.lowercased()
        let fromBare = message.from.map(Address.bare)
        let toBare = message.to.map(Address.bare)

        switch source {
        case .live:
            guard let from = message.from else { return .ignore }
            return classify(remote: from, outgoing: false, knownRooms: knownRooms)
        case .carbonSent:
            // A "sent" carbon claims we wrote this; it must be from us.
            guard fromBare == accountBare, let to = message.to else { return .ignore }
            return classify(remote: to, outgoing: true, knownRooms: knownRooms)
        case .carbonReceived:
            guard toBare == accountBare, let from = message.from else { return .ignore }
            return classify(remote: from, outgoing: false, knownRooms: knownRooms)
        case .archive:
            if fromBare == accountBare, let to = message.to {
                return classify(remote: to, outgoing: true, knownRooms: knownRooms)
            }
            guard toBare == accountBare, let from = message.from else { return .ignore }
            return classify(remote: from, outgoing: false, knownRooms: knownRooms)
        }
    }

    private static func classify(remote: String, outgoing: Bool, knownRooms: Set<String>) -> MessageRoute {
        let bare = Address.bare(remote)
        if knownRooms.contains(bare) {
            guard let nick = Address.resource(remote) else {
                // Addressed to the room itself but not type=groupchat, e.g. a
                // service notice. Not private, and not safe to treat as a chat.
                return .ignore
            }
            return .roomPrivate(peer: "\(bare)/\(nick)", room: bare, nick: nick, outgoing: outgoing)
        }
        return .chat(peer: bare, outgoing: outgoing)
    }

    /// Identifier used to spot the same message arriving by several paths
    /// (live, carbon, archive, room reflection). Scoped per conversation.
    public static func dedupeKey(originID: String?, stanzaID: String?, from: String?, timestamp: Date?, body: String) -> String {
        if let originID, !originID.isEmpty { return "id:\(originID)" }
        if let stanzaID, !stanzaID.isEmpty { return "id:\(stanzaID)" }
        if let timestamp {
            return "hash:\(from ?? "")|\(Int(timestamp.timeIntervalSince1970))|\(body)"
        }
        // No identity and no server timestamp: treat as unique.
        return "uuid:\(UUID().uuidString)"
    }

    /// The time to display. `<delay>` is sender-controlled, so a timestamp in
    /// the future is clamped rather than pinning a message to the list's end.
    public static func effectiveTimestamp(delay: Date?, now: Date = Date()) -> Date {
        guard let delay else { return now }
        return min(delay, now)
    }
}
