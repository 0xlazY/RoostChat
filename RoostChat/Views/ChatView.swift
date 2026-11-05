import SwiftData
import SwiftUI

/// A Pidgin-style conversation log: `(12:03:14) alice: hello`, one line per
/// message, rather than chat bubbles.
struct ChatView: View {
    let route: ChatRoute

    @EnvironmentObject private var manager: SessionManager
    @Query private var newestFirst: [StoredMessage]
    @State private var draft = ""
    @State private var announcedComposing = false
    @State private var showingOccupants = false

    private static let historyLimit = 500

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
    private var messages: [StoredMessage] { newestFirst.reversed() }

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

    var body: some View {
        VStack(spacing: 0) {
            if let banner {
                Text(verbatim: banner)
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(.yellow.opacity(0.25))
            }
            log
            if isTyping {
                Text(verbatim: "\(route.title) is typing…")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            Divider()
            composer
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if route.kind == .room {
                Button("Members", systemImage: "person.3") { showingOccupants = true }
            }
        }
        .sheet(isPresented: $showingOccupants) {
            OccupantsView(names: session?.occupants[route.peer] ?? [])
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

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(messages) { message in
                        MessageLine(message: message) {
                            session?.resend(message, route: route)
                        }
                        .id(message.persistentModelID)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.persistentModelID) { _, newest in
                if let newest {
                    withAnimation { proxy.scrollTo(newest, anchor: .bottom) }
                }
                manager.markRead(account: route.account, peer: route.peer)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onChange(of: draft) { _, text in updateComposing(text) }
            Button {
                session?.send(draft, route: route)
                draft = ""
                announcedComposing = false
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .accessibilityLabel("Send")
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(8)
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

private struct MessageLine: View {
    let message: StoredMessage
    let resend: () -> Void

    private var stateSuffix: String {
        guard message.outgoing else { return "" }
        switch message.state {
        case .sending: return " ⏳"
        case .delivered: return " ✓"
        case .failed: return " ⚠️"
        case .sent, .received: return ""
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("Hms")
        return formatter
    }()

    private static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMdHms")
        return formatter
    }()

    private var stamp: String {
        let formatter = Calendar.current.isDateInToday(message.timestamp) ? Self.time : Self.dateTime
        return formatter.string(from: message.timestamp)
    }

    // Bodies and names are remote input: always verbatim, never Markdown.
    private var line: Text {
        let time: Text = Text(verbatim: "(\(stamp)) ").foregroundColor(.secondary).font(.caption)
        let name: Text = Text(verbatim: "\(message.sender): ").foregroundColor(message.outgoing ? .blue : .red).bold()
        let body: Text = Text(verbatim: message.body)
        let state: Text = Text(verbatim: stateSuffix).font(.caption)
        return time + name + body + state
    }

    /// The first web link in the message, for opening from the menu.
    private var firstLink: URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(message.body.startIndex..., in: message.body)
        guard let url = detector.firstMatch(in: message.body, range: range)?.url,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            line
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let link = message.mediaURL {
                MediaAttachment(link: link)
            }
        }
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.body }
                if let firstLink {
                    Link(destination: firstLink) {
                        Label("Open Link", systemImage: "safari")
                    }
                }
                if message.outgoing && message.state == .failed {
                    Button("Send Again", systemImage: "arrow.clockwise", action: resend)
                }
            }
    }
}

private struct OccupantsView: View {
    let names: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(names, id: \.self) { Text(verbatim: $0) }
                .navigationTitle("Members (\(names.count))")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}
