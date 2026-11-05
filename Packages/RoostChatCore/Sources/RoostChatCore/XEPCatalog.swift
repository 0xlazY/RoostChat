import Foundation

public struct XEPEntry: Identifiable, Equatable, Sendable {
    public let spec: String
    public let name: String
    /// Namespace prefixes that identify this feature in service discovery.
    public let namespaces: [String]
    public let usedByApp: Bool
    public let appNote: String?

    public var id: String { spec }

    init(_ spec: String, _ name: String, _ namespaces: [String], used: Bool, note: String? = nil) {
        self.spec = spec
        self.name = name
        self.namespaces = namespaces
        self.usedByApp = used
        self.appNote = note
    }
}

public enum XEPCatalog {
    public static let entries: [XEPEntry] = [
        XEPEntry("RFC 6120", "XMPP Core", ["urn:ietf:params:xml:ns:xmpp-tls", "urn:ietf:params:xml:ns:xmpp-sasl", "urn:ietf:params:xml:ns:xmpp-bind"], used: true),
        XEPEntry("RFC 6121", "Instant Messaging and Presence", ["jabber:iq:roster", "urn:xmpp:features:rosterver"], used: true),
        XEPEntry("XEP-0030", "Service Discovery", ["http://jabber.org/protocol/disco"], used: true),
        XEPEntry("XEP-0045", "Multi-User Chat", ["http://jabber.org/protocol/muc"], used: true),
        XEPEntry("XEP-0066", "Out of Band Data", ["jabber:x:oob"], used: true, note: "Receiving links only"),
        XEPEntry("XEP-0085", "Chat State Notifications", ["http://jabber.org/protocol/chatstates"], used: true),
        XEPEntry("XEP-0092", "Software Version", ["jabber:iq:version"], used: true),
        XEPEntry("XEP-0115", "Entity Capabilities", ["http://jabber.org/protocol/caps"], used: true),
        XEPEntry("XEP-0184", "Message Delivery Receipts", ["urn:xmpp:receipts"], used: true),
        XEPEntry("XEP-0198", "Stream Management", ["urn:xmpp:sm"], used: true),
        XEPEntry("XEP-0199", "XMPP Ping", ["urn:xmpp:ping"], used: true),
        XEPEntry("XEP-0203", "Delayed Delivery", ["urn:xmpp:delay"], used: true),
        XEPEntry("XEP-0249", "Direct MUC Invitations", ["jabber:x:conference"], used: true, note: "Receiving only"),
        XEPEntry("XEP-0280", "Message Carbons", ["urn:xmpp:carbons"], used: true),
        XEPEntry("XEP-0313", "Message Archive Management", ["urn:xmpp:mam"], used: true, note: "Personal archive"),
        XEPEntry("XEP-0359", "Unique and Stable Stanza IDs", ["urn:xmpp:sid"], used: true),
        XEPEntry("XEP-0368", "SRV Records for XMPP over TLS", [], used: true),
        XEPEntry("XEP-0054", "vcard-temp", ["vcard-temp"], used: false),
        XEPEntry("XEP-0060", "Publish-Subscribe", ["http://jabber.org/protocol/pubsub"], used: false),
        XEPEntry("XEP-0077", "In-Band Registration", ["jabber:iq:register", "http://jabber.org/features/iq-register"], used: false),
        XEPEntry("XEP-0084", "User Avatar", ["urn:xmpp:avatar"], used: false),
        XEPEntry("XEP-0163", "Personal Eventing Protocol", ["http://jabber.org/protocol/pubsub#publish"], used: false),
        XEPEntry("XEP-0166", "Jingle", ["urn:xmpp:jingle"], used: false),
        XEPEntry("XEP-0191", "Blocking Command", ["urn:xmpp:blocking"], used: false),
        XEPEntry("XEP-0352", "Client State Indication", ["urn:xmpp:csi"], used: false),
        XEPEntry("XEP-0357", "Push Notifications", ["urn:xmpp:push"], used: false),
        XEPEntry("XEP-0363", "HTTP File Upload", ["urn:xmpp:http:upload"], used: false),
        XEPEntry("XEP-0384", "OMEMO Encryption", ["eu.siacs.conversations.axolotl", "urn:xmpp:omemo"], used: false),
        XEPEntry("XEP-0402", "PEP Native Bookmarks", ["urn:xmpp:bookmarks"], used: false),
    ]

    public static var appSupported: [XEPEntry] { entries.filter(\.usedByApp) }
    public static var notImplemented: [XEPEntry] { entries.filter { !$0.usedByApp } }

    /// The catalog entry for a discovered namespace, preferring the longest match
    /// so that pubsub#publish resolves to PEP rather than plain pubsub.
    public static func entry(forNamespace namespace: String) -> XEPEntry? {
        var best: (entry: XEPEntry, length: Int)?
        for entry in entries {
            for prefix in entry.namespaces where matches(namespace, prefix: prefix) {
                if prefix.count > (best?.length ?? -1) { best = (entry, prefix.count) }
            }
        }
        return best?.entry
    }

    private static func matches(_ namespace: String, prefix: String) -> Bool {
        guard namespace.hasPrefix(prefix) else { return false }
        guard let next = namespace.dropFirst(prefix.count).first else { return true }
        return next == ":" || next == "#" || next == "/" || next == "+"
    }
}
