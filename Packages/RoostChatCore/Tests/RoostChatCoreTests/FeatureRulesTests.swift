import XCTest
@testable import RoostChatCore

final class TLSPolicyTests: XCTestCase {
    func testTrustedCertificateNeedsNoPin() {
        XCTAssertEqual(TLSPolicy.decide(systemTrusted: true, allowUnverified: false, pinned: nil, seen: "a"), .acceptVerified)
        XCTAssertEqual(TLSPolicy.decide(systemTrusted: true, allowUnverified: true, pinned: "old", seen: "new"), .acceptVerified)
    }

    func testUnverifiedRejectedByDefault() {
        XCTAssertEqual(TLSPolicy.decide(systemTrusted: false, allowUnverified: false, pinned: "a", seen: "a"), .rejectUnverified)
    }

    func testFirstUnverifiedCertificateIsPinned() {
        XCTAssertEqual(TLSPolicy.decide(systemTrusted: false, allowUnverified: true, pinned: nil, seen: "a"), .acceptAndPin)
    }

    func testPinnedCertificateAccepted() {
        XCTAssertEqual(TLSPolicy.decide(systemTrusted: false, allowUnverified: true, pinned: "AB", seen: "ab"), .acceptPinned)
    }

    func testChangedCertificateRejected() {
        let decision = TLSPolicy.decide(systemTrusted: false, allowUnverified: true, pinned: "a", seen: "b")
        XCTAssertEqual(decision, .rejectChanged(pinned: "a"))
        XCTAssertFalse(decision.accepts)
    }

    func testMissingFingerprintRejected() {
        XCTAssertEqual(TLSPolicy.decide(systemTrusted: false, allowUnverified: true, pinned: nil, seen: nil), .rejectUnverified)
    }
}

final class ServerAddressTests: XCTestCase {
    func testDefaultsDependOnTLSMode() {
        XCTAssertEqual(ServerAddress.parse(host: " xmpp.example.org ", port: "", directTLS: false)?.port, 5222)
        XCTAssertEqual(ServerAddress.parse(host: "xmpp.example.org", port: "", directTLS: true)?.port, 5223)
        XCTAssertEqual(ServerAddress.parse(host: "xmpp.example.org", port: "443", directTLS: true)?.host, "xmpp.example.org")
    }

    func testInvalidValues() {
        XCTAssertNil(ServerAddress.parse(host: "", port: "5222", directTLS: false))
        XCTAssertNil(ServerAddress.parse(host: "bad host", port: "", directTLS: false))
        XCTAssertNil(ServerAddress.parse(host: "h", port: "0", directTLS: false))
        XCTAssertNil(ServerAddress.parse(host: "h", port: "70000", directTLS: false))
        XCTAssertNil(ServerAddress.parse(host: "h", port: "abc", directTLS: false))
    }
}

final class LogRedactionTests: XCTestCase {
    func testCredentialsAlwaysRemoved() {
        let samples = [
            "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>c2VjcmV0</auth>",
            "<response xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>c2VjcmV0</response>",
            "<challenge xmlns='x'>c2VjcmV0</challenge>",
            "<success xmlns='x'>c2VjcmV0</success>",
            "<presence><x><password>c2VjcmV0</password></x></presence>",
        ]
        for sample in samples {
            let redacted = LogRedaction.redact(sample, includeMessageBodies: true)
            XCTAssertFalse(redacted.contains("c2VjcmV0"), sample)
            XCTAssertTrue(redacted.contains("[redacted]"), sample)
        }
    }

    func testBodiesFollowSetting() {
        let xml = "<message to='a@b'><body>hello\nthere</body></message>"
        XCTAssertFalse(LogRedaction.redact(xml, includeMessageBodies: false).contains("hello"))
        XCTAssertTrue(LogRedaction.redact(xml, includeMessageBodies: false).contains("to='a@b'"))
        XCTAssertTrue(LogRedaction.redact(xml, includeMessageBodies: true).contains("hello"))
    }

    func testSimilarNamesAndEmptyElementsUntouched() {
        XCTAssertEqual(LogRedaction.redact("<authors>keep</authors>", includeMessageBodies: false), "<authors>keep</authors>")
        XCTAssertEqual(LogRedaction.redact("<success xmlns='x'/><iq>keep</iq>", includeMessageBodies: false), "<success xmlns='x'/><iq>keep</iq>")
    }
}

final class MediaLinkTests: XCTestCase {
    func testOutOfBandLinkWins() {
        XCTAssertEqual(MediaLink.detect(oob: "https://a.org/f.pdf", body: "see"), "https://a.org/f.pdf")
    }

    func testBareImageLinkDetected() {
        XCTAssertEqual(MediaLink.detect(oob: nil, body: " https://a.org/cat.JPG\n"), "https://a.org/cat.JPG")
    }

    func testOtherTextIsNotMedia() {
        XCTAssertNil(MediaLink.detect(oob: nil, body: "look https://a.org/cat.jpg"))
        XCTAssertNil(MediaLink.detect(oob: nil, body: "https://a.org/page.html"))
        XCTAssertNil(MediaLink.detect(oob: nil, body: nil))
    }

    func testOnlyHTTPSAccepted() {
        for link in ["http://a.org/c.jpg", "file:///etc/passwd", "ftp://a.org/c.png", "javascript:alert(1)"] {
            XCTAssertNil(MediaLink.detect(oob: link, body: link), link)
        }
    }

    func testImageDetectionIgnoresQuery() {
        XCTAssertTrue(MediaLink.isImage("https://a.org/c.png?size=1"))
        XCTAssertFalse(MediaLink.isImage("https://a.org/c.pdf"))
    }
}

final class NotificationPolicyTests: XCTestCase {
    func testDirectMessagesAlwaysNotify() {
        XCTAssertTrue(NotificationPolicy.shouldNotify(isRoom: false, mode: .off, body: "x", ownNickname: nil))
    }

    func testRoomModes() {
        XCTAssertTrue(NotificationPolicy.shouldNotify(isRoom: true, mode: .all, body: "x", ownNickname: "me"))
        XCTAssertFalse(NotificationPolicy.shouldNotify(isRoom: true, mode: .off, body: "hi me", ownNickname: "me"))
        XCTAssertTrue(NotificationPolicy.shouldNotify(isRoom: true, mode: .mentions, body: "hi JEAN!", ownNickname: "jean"))
        XCTAssertFalse(NotificationPolicy.shouldNotify(isRoom: true, mode: .mentions, body: "hello", ownNickname: "jean"))
        XCTAssertFalse(NotificationPolicy.shouldNotify(isRoom: true, mode: .mentions, body: "hello", ownNickname: ""))
    }
}

final class XEPCatalogTests: XCTestCase {
    func testVersionedNamespacesResolve() {
        XCTAssertEqual(XEPCatalog.entry(forNamespace: "urn:xmpp:mam:2")?.spec, "XEP-0313")
        XCTAssertEqual(XEPCatalog.entry(forNamespace: "urn:xmpp:http:upload:0")?.spec, "XEP-0363")
        XCTAssertEqual(XEPCatalog.entry(forNamespace: "http://jabber.org/protocol/disco#info")?.spec, "XEP-0030")
    }

    func testLongestPrefixWins() {
        XCTAssertEqual(XEPCatalog.entry(forNamespace: "http://jabber.org/protocol/pubsub#publish")?.spec, "XEP-0163")
        XCTAssertEqual(XEPCatalog.entry(forNamespace: "http://jabber.org/protocol/pubsub#retrieve-items")?.spec, "XEP-0060")
    }

    func testPrefixMustEndAtBoundary() {
        XCTAssertNil(XEPCatalog.entry(forNamespace: "urn:xmpp:smart"))
        XCTAssertNil(XEPCatalog.entry(forNamespace: "something:else"))
    }

    func testSpecsAreUnique() {
        XCTAssertEqual(Set(XEPCatalog.entries.map(\.spec)).count, XEPCatalog.entries.count)
    }
}

final class ChatTimelineTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute))!
    }

    func testFirstMessageHasHeader() {
        XCTAssertTrue(ChatTimeline.needsHeader(previous: nil, current: date(1, 12, 0), calendar: calendar))
    }

    func testCloseMessagesShareHeader() {
        XCTAssertFalse(ChatTimeline.needsHeader(previous: date(1, 12, 0), current: date(1, 12, 14), calendar: calendar))
    }

    func testLongPauseGetsHeader() {
        XCTAssertTrue(ChatTimeline.needsHeader(previous: date(1, 12, 0), current: date(1, 12, 15), calendar: calendar))
    }

    func testNewDayGetsHeaderEvenAfterShortPause() {
        XCTAssertTrue(ChatTimeline.needsHeader(previous: date(1, 23, 59), current: date(2, 0, 1), calendar: calendar))
    }
}
