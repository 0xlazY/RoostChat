import Foundation

public struct XEPEntry: Identifiable, Equatable, Sendable {
    public let spec: String
    public let name: String
    /// Namespace prefixes that identify this feature in service discovery.
    public let namespaces: [String]

    public var id: String { spec }

    init(_ spec: String, _ name: String, _ namespaces: [String]) {
        self.spec = spec
        self.name = name
        self.namespaces = namespaces
    }
}

public enum XEPCatalog {
    public static let entries: [XEPEntry] = [
        XEPEntry("RFC 6120", "XMPP Core", ["urn:ietf:params:xml:ns:xmpp-tls", "urn:ietf:params:xml:ns:xmpp-sasl", "urn:ietf:params:xml:ns:xmpp-bind"]),
        XEPEntry("RFC 6121", "Instant Messaging and Presence", ["jabber:iq:roster", "urn:xmpp:features:rosterver"]),
        XEPEntry("XEP-0030", "Service Discovery", ["http://jabber.org/protocol/disco"]),
        XEPEntry("XEP-0045", "Multi-User Chat", ["http://jabber.org/protocol/muc"]),
        XEPEntry("XEP-0066", "Out of Band Data", ["jabber:x:oob"]),
        XEPEntry("XEP-0085", "Chat State Notifications", ["http://jabber.org/protocol/chatstates"]),
        XEPEntry("XEP-0092", "Software Version", ["jabber:iq:version"]),
        XEPEntry("XEP-0115", "Entity Capabilities", ["http://jabber.org/protocol/caps"]),
        XEPEntry("XEP-0184", "Message Delivery Receipts", ["urn:xmpp:receipts"]),
        XEPEntry("XEP-0198", "Stream Management", ["urn:xmpp:sm"]),
        XEPEntry("XEP-0199", "XMPP Ping", ["urn:xmpp:ping"]),
        XEPEntry("XEP-0203", "Delayed Delivery", ["urn:xmpp:delay"]),
        XEPEntry("XEP-0249", "Direct MUC Invitations", ["jabber:x:conference"]),
        XEPEntry("XEP-0280", "Message Carbons", ["urn:xmpp:carbons"]),
        XEPEntry("XEP-0313", "Message Archive Management", ["urn:xmpp:mam"]),
        XEPEntry("XEP-0359", "Unique and Stable Stanza IDs", ["urn:xmpp:sid"]),
        XEPEntry("XEP-0012", "Last Activity", ["jabber:iq:last"]),
        XEPEntry("XEP-0013", "Flexible Offline Message Retrieval", ["http://jabber.org/protocol/offline"]),
        XEPEntry("XEP-0016", "Privacy Lists", ["jabber:iq:privacy"]),
        XEPEntry("XEP-0049", "Private XML Storage", ["jabber:iq:private"]),
        XEPEntry("XEP-0050", "Ad-Hoc Commands", ["http://jabber.org/protocol/commands"]),
        XEPEntry("XEP-0065", "SOCKS5 Bytestreams", ["http://jabber.org/protocol/bytestreams"]),
        XEPEntry("XEP-0133", "Service Administration", ["http://jabber.org/protocol/admin"]),
        XEPEntry("XEP-0157", "Contact Addresses", ["http://jabber.org/network/serverinfo"]),
        XEPEntry("XEP-0160", "Offline Messages", ["msgoffline"]),
        XEPEntry("XEP-0202", "Entity Time", ["urn:xmpp:time"]),
        XEPEntry("XEP-0215", "External Service Discovery", ["urn:xmpp:extdisco"]),
        XEPEntry("XEP-0398", "Avatar Conversion", ["urn:xmpp:pep-vcard-conversion"]),
        XEPEntry("XEP-0054", "vcard-temp", ["vcard-temp"]),
        XEPEntry("XEP-0060", "Publish-Subscribe", ["http://jabber.org/protocol/pubsub"]),
        XEPEntry("XEP-0077", "In-Band Registration", ["jabber:iq:register", "http://jabber.org/features/iq-register"]),
        XEPEntry("XEP-0084", "User Avatar", ["urn:xmpp:avatar"]),
        XEPEntry("XEP-0163", "Personal Eventing Protocol", ["http://jabber.org/protocol/pubsub#publish"]),
        XEPEntry("XEP-0166", "Jingle", ["urn:xmpp:jingle"]),
        XEPEntry("XEP-0191", "Blocking Command", ["urn:xmpp:blocking"]),
        XEPEntry("XEP-0352", "Client State Indication", ["urn:xmpp:csi"]),
        XEPEntry("XEP-0357", "Push Notifications", ["urn:xmpp:push"]),
        XEPEntry("XEP-0363", "HTTP File Upload", ["urn:xmpp:http:upload"]),
        XEPEntry("XEP-0384", "OMEMO Encryption", ["eu.siacs.conversations.axolotl", "urn:xmpp:omemo"]),
        XEPEntry("XEP-0402", "PEP Native Bookmarks", ["urn:xmpp:bookmarks"]),
    ]

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
