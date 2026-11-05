import RoostChatCore
import SwiftData
import SwiftUI

/// One bubble and how it sits among its neighbours.
private struct ChatRow: Identifiable {
    let message: StoredMessage
    let dateHeader: String?
    /// First of a run from the same sender: shows the name in rooms.
    let startsGroup: Bool
    /// Last of a run: shows the avatar and the bubble's tail.
    let endsGroup: Bool
    let statusText: String?

    var id: PersistentIdentifier { message.persistentModelID }
}

/// A conversation laid out like iMessage: blue outgoing bubbles on the right, gray
/// incoming ones on the left with the sender's picture.
struct ChatView: View {
    let route: ChatRoute

    @EnvironmentObject private var manager: SessionManager
    @Query private var newestFirst: [StoredMessage]
    @State private var draft = ""
    @State private var announcedComposing = false
    @State private var showingOccupants = false
    @FocusState private var composerFocused: Bool

    private static let historyLimit = 500
    private static let bottomID = "bottom"
    /// A pause this long starts a new run of bubbles.
    private static let groupGap: TimeInterval = 5 * 60
    /// A pause this long gets a centered date header.
    private static let headerGap: TimeInterval = 60 * 60

    init(route: ChatRoute) {
        self.route = route
        let id = route.id
        var descriptor = FetchDescriptor<StoredMessage>(
            predicate: #Predicate<StoredMessage> { $0.conversationID == id },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = Self.historyLimit
        _newestFirst = Query(descriptor)
    }

    private var session: AccountSession? { manager.session(for: route.account) }

    private var rows: [ChatRow] {
        let messages = Array(newestFirst.reversed())
        let lastDelivered = messages.last { $0.outgoing && $0.state == .delivered }?.persistentModelID
        return messages.indices.map { index in
            let message = messages[index]
            let previous = index > 0 ? messages[index - 1] : nil
            let next = index + 1 < messages.count ? messages[index + 1] : nil
            let header = previous.map { message.timestamp.timeIntervalSince($0.timestamp) >= Self.headerGap } ?? true
            let startsGroup = header || !sameRun(previous, message)
            let nextHasHeader = next.map { $0.timestamp.timeIntervalSince(message.timestamp) >= Self.headerGap } ?? false
            let endsGroup = nextHasHeader || !sameRun(message, next)
            var status: String?
            if message.outgoing {
                switch message.state {
                case .sending: status = "Sending…"
                case .failed: status = "Not Delivered"
                case .delivered: status = message.persistentModelID == lastDelivered ? "Delivered" : nil
                case .sent, .received: status = nil
                }
            }
            return ChatRow(message: message,
                           dateHeader: header ? Self.dateLabel(message.timestamp) : nil,
                           startsGroup: startsGroup, endsGroup: endsGroup, statusText: status)
        }
    }

    private func sameRun(_ first: StoredMessage?, _ second: StoredMessage?) -> Bool {
        guard let first, let second else { return false }
        return first.outgoing == second.outgoing && first.sender == second.sender
            && second.timestamp.timeIntervalSince(first.timestamp) < Self.groupGap
    }

    private static func dateLabel(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) \(time)"
    }

    private var banner: String? {
        guard let session else { return "This account was removed." }
        if session.status != .online { return session.status.label }
        guard route.kind == .room else { return nil }
        switch session.roomStatus[route.peer] {
        case .joined: return nil
        case .failed(let reason): return "Couldn't join: \(reason)"
        case .joining, .none: return "Joining room…"
        }
    }

    private var isTyping: Bool {
        route.kind == .chat && session?.typingPeers.contains(route.peer) == true
    }

    private func avatarKey(for message: StoredMessage) -> String {
        route.kind == .room ? "\(route.peer)/\(message.sender)" : route.peer
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in
                        MessageRowView(row: row,
                                       showSenderName: route.kind == .room,
                                       avatarKey: avatarKey(for: row.message),
                                       resend: { session?.resend(row.message, route: route) })
                    }
                    if isTyping {
                        TypingBubble()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 36)
                            .padding(.top, 4)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            // Pulling down on the conversation drags the keyboard away, as in Messages.
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let banner {
                    Text(verbatim: banner)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(.yellow.opacity(0.25))
                        .background(.bar)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
            .onChange(of: newestFirst.first?.persistentModelID) { _, _ in
                withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                manager.markRead(account: route.account, peer: route.peer)
            }
            .onChange(of: composerFocused) { _, focused in
                if focused {
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    AvatarView(key: route.peer, name: route.title, size: 30)
                    Text(verbatim: route.title).font(.caption2).lineLimit(1)
                }
            }
            if route.kind == .room {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Members", systemImage: "person.2") { showingOccupants = true }
                }
            }
        }
        .sheet(isPresented: $showingOccupants) {
            OccupantsView(room: route.peer, names: session?.occupants[route.peer] ?? [])
        }
        .onAppear {
            manager.activeRoute = route
            manager.markRead(account: route.account, peer: route.peer)
        }
        .onDisappear {
            if manager.activeRoute == route { manager.activeRoute = nil }
            stopComposing()
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.leading, 14)
                .padding(.vertical, 7)
                .onChange(of: draft) { _, text in updateComposing(text) }
            if canSend {
                Button {
                    session?.send(draft, route: route)
                    draft = ""
                    announcedComposing = false
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white, .blue)
                }
                .accessibilityLabel("Send")
                .padding(.trailing, 3)
                .padding(.bottom, 3)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(Color(.systemGray3), lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func updateComposing(_ text: String) {
        guard route.kind == .chat else { return }
        let composing = !text.isEmpty
        if composing != announcedComposing {
            announcedComposing = composing
            session?.sendChatState(composing: composing, to: route.peer)
        }
    }

    private func stopComposing() {
        if announcedComposing {
            announcedComposing = false
            session?.sendChatState(composing: false, to: route.peer)
        }
    }
}

private struct MessageRowView: View {
    let row: ChatRow
    let showSenderName: Bool
    let avatarKey: String
    let resend: () -> Void

    private static let avatarSize: CGFloat = 28

    private var message: StoredMessage { row.message }

    /// A message that is only a link to an image shows just the image.
    private var isOnlyMedia: Bool {
        guard let link = message.mediaURL, MediaLink.isImage(link) else { return false }
        return message.body.trimmingCharacters(in: .whitespacesAndNewlines) == link
    }

    var body: some View {
        VStack(spacing: 2) {
            if let header = row.dateHeader {
                Text(verbatim: header)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if message.outgoing {
                    Spacer(minLength: 56)
                } else {
                    avatar
                }
                VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 2) {
                    if !message.outgoing && showSenderName && row.startsGroup {
                        Text(verbatim: message.sender)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                    }
                    if !isOnlyMedia {
                        bubble
                    }
                    if let link = message.mediaURL {
                        MediaAttachment(link: link)
                    }
                }
                if !message.outgoing {
                    Spacer(minLength: 40)
                }
            }
            .padding(.top, row.startsGroup ? 6 : 0)
            if let status = row.statusText {
                statusLine(status)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if row.endsGroup {
            AvatarView(key: avatarKey, name: message.sender, size: Self.avatarSize)
        } else {
            Color.clear.frame(width: Self.avatarSize, height: 1)
        }
    }

    private var bubble: some View {
        Text(linkified)
            .foregroundStyle(message.outgoing ? Color.white : Color.primary)
            .tint(message.outgoing ? Color.white : Color.blue)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(message.outgoing ? Color.blue : Color(.systemGray5), in: bubbleShape)
            .contentShape(.contextMenuPreview, bubbleShape)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.body }
                if message.outgoing && message.state == .failed {
                    Button("Send Again", systemImage: "arrow.clockwise", action: resend)
                }
            }
    }

    /// The corner toward the sender stays tight on the last bubble of a run.
    private var bubbleShape: UnevenRoundedRectangle {
        let tail: CGFloat = row.endsGroup ? 5 : 18
        return UnevenRoundedRectangle(topLeadingRadius: 18,
                                      bottomLeadingRadius: message.outgoing ? 18 : tail,
                                      bottomTrailingRadius: message.outgoing ? tail : 18,
                                      topTrailingRadius: 18,
                                      style: .continuous)
    }

    /// The body as plain text with only web links made tappable. Remote input is
    /// never parsed as Markdown.
    private var linkified: AttributedString {
        var text = AttributedString(message.body)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        let body = message.body
        for match in detector.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let stringRange = Range(match.range, in: body),
                  let range = Range(stringRange, in: text) else { continue }
            text[range].link = url
            text[range].underlineStyle = .single
        }
        return text
    }

    @ViewBuilder
    private func statusLine(_ status: String) -> some View {
        HStack(spacing: 4) {
            Spacer()
            if message.state == .failed {
                Button(action: resend) {
                    Label(status, systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            } else {
                Text(verbatim: status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, 4)
    }
}

private struct TypingBubble: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(Color(.systemGray)).frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color(.systemGray5), in: Capsule())
        .accessibilityLabel("Typing")
    }
}

private struct OccupantsView: View {
    let room: String
    let names: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(names, id: \.self) { name in
                HStack(spacing: 12) {
                    AvatarView(key: "\(room)/\(name)", name: name, size: 36)
                    Text(verbatim: name)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Members (\(names.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
