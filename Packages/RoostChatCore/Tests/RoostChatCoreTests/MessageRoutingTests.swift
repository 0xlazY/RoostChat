import XCTest
@testable import RoostChatCore

final class MessageRoutingTests: XCTestCase {
    private let me = "me@example.org"
    private func route(_ from: String?, _ to: String?, type: String? = "chat", body: String? = "hi",
                       source: MessageSource = .live, rooms: Set<String> = []) -> MessageRoute {
        MessageRouting.route(.init(from: from, to: to, type: type, body: body), source: source, account: me, knownRooms: rooms)
    }

    func testLiveMessageGoesToSenderBareJID() {
        XCTAssertEqual(route("Alice@Example.org/phone", me), .chat(peer: "alice@example.org", outgoing: false))
    }

    func testMessagesWithoutBodyAreIgnored() {
        XCTAssertEqual(route("alice@example.org", me, body: nil), .ignore)
        XCTAssertEqual(route("alice@example.org", me, body: ""), .ignore)
    }

    func testErrorBounceIsNotShownAsIncoming() {
        XCTAssertEqual(route("alice@example.org", me, type: "error"), .ignore)
    }

    func testForgedSentCarbonIsRejected() {
        // Mallory forwards a "sent" carbon claiming to be from Alice.
        XCTAssertEqual(route("alice@example.org/x", "bob@example.org", source: .carbonSent), .ignore)
    }

    func testRealSentCarbonIsOutgoingToRecipient() {
        XCTAssertEqual(route("me@example.org/desktop", "bob@example.org", source: .carbonSent),
                       .chat(peer: "bob@example.org", outgoing: true))
    }

    func testReceivedCarbonMustBeAddressedToUs() {
        XCTAssertEqual(route("alice@example.org", "bob@example.org", source: .carbonReceived), .ignore)
        XCTAssertEqual(route("alice@example.org", "me@example.org/desktop", source: .carbonReceived),
                       .chat(peer: "alice@example.org", outgoing: false))
    }

    func testArchiveDirectionFollowsSender() {
        XCTAssertEqual(route("me@example.org/a", "bob@example.org", source: .archive),
                       .chat(peer: "bob@example.org", outgoing: true))
        XCTAssertEqual(route("bob@example.org/a", "me@example.org", source: .archive),
                       .chat(peer: "bob@example.org", outgoing: false))
    }

    func testArchiveMessageNotInvolvingUsIsRejected() {
        XCTAssertEqual(route("alice@example.org", "bob@example.org", source: .archive), .ignore)
    }

    func testGroupchatInPersonalArchiveIsIgnored() {
        XCTAssertEqual(route("room@conf.example.org/a", me, type: "groupchat", source: .archive), .ignore)
    }

    func testRoomPrivateMessageStaysSeparateFromRoom() {
        XCTAssertEqual(route("room@conf.example.org/Ann", me, rooms: ["room@conf.example.org"]),
                       .roomPrivate(peer: "room@conf.example.org/Ann", room: "room@conf.example.org", nick: "Ann", outgoing: false))
    }

    func testNonGroupchatFromBareRoomIsNotAChat() {
        XCTAssertEqual(route("room@conf.example.org", me, rooms: ["room@conf.example.org"]), .ignore)
    }

    func testDedupePrefersOriginID() {
        XCTAssertEqual(MessageRouting.dedupeKey(originID: "o", stanzaID: "s", from: "a", timestamp: nil, body: "b"), "id:o")
        XCTAssertEqual(MessageRouting.dedupeKey(originID: nil, stanzaID: "s", from: "a", timestamp: nil, body: "b"), "id:s")
    }

    func testDedupeWithoutIDsUsesTimestampOrIsUnique() {
        let date = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(MessageRouting.dedupeKey(originID: nil, stanzaID: nil, from: "a", timestamp: date, body: "b"), "hash:a|100|b")
        let first = MessageRouting.dedupeKey(originID: nil, stanzaID: nil, from: "a", timestamp: nil, body: "b")
        let second = MessageRouting.dedupeKey(originID: nil, stanzaID: nil, from: "a", timestamp: nil, body: "b")
        XCTAssertNotEqual(first, second)
    }

    func testFutureTimestampIsClamped() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(MessageRouting.effectiveTimestamp(delay: Date(timeIntervalSince1970: 9999), now: now), now)
        let past = Date(timeIntervalSince1970: 10)
        XCTAssertEqual(MessageRouting.effectiveTimestamp(delay: past, now: now), past)
        XCTAssertEqual(MessageRouting.effectiveTimestamp(delay: nil, now: now), now)
    }
}

final class AddressTests: XCTestCase {
    func testNormalizesCaseAndWhitespace() {
        XCTAssertEqual(Address.normalizedBare("  Alice@Example.ORG \n"), "alice@example.org")
    }

    func testRejectsInvalidAddresses() {
        for bad in ["", "alice", "@example.org", "alice@", "a@b@c", "alice@example.org/phone", "al ice@example.org", "alice@.org", "alice@org."] {
            XCTAssertNil(Address.normalizedBare(bad), bad)
        }
    }

    func testBareAndResource() {
        XCTAssertEqual(Address.bare("A@B.org/Res/x"), "a@b.org")
        XCTAssertEqual(Address.resource("a@b.org/Res/x"), "Res/x")
        XCTAssertNil(Address.resource("a@b.org"))
        XCTAssertNil(Address.resource("a@b.org/"))
    }
}

final class ReconnectTests: XCTestCase {
    func testBackoffGrowsAndCaps() {
        XCTAssertEqual(Reconnect.delay(attempt: 0, jitter: 0), 1)
        XCTAssertEqual(Reconnect.delay(attempt: 3, jitter: 0), 8)
        XCTAssertEqual(Reconnect.delay(attempt: 50, jitter: 0), 120)
        XCTAssertEqual(Reconnect.delay(attempt: 50, jitter: 1), 150)
        XCTAssertEqual(Reconnect.delay(attempt: -1, jitter: 5), 1.25)
    }
}
