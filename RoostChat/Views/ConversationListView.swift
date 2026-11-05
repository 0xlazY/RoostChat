import SwiftData
import SwiftUI

/// The conversation list, laid out like Messages.
struct ConversationListView: View {
    @EnvironmentObject private var manager: SessionManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredConversation.lastTimestamp, order: .reverse) private var conversations: [StoredConversation]
    @State private var path: [ChatRoute] = []
    @State private var search = ""
    @State private var messageMatches: [StoredMessage] = []

    private static let maxMessageMatches = 50

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var titleMatches: [StoredConversation] {
        conversations.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if conversations.isEmpty {
                    ContentUnavailableView("No conversations", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Tap a buddy to start chatting."))
                } else {
                    List {
                        if isSearching {
                            searchResults
                        } else {
                            ForEach(conversations) { conversationLink($0) }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $search)
                    .overlay {
                        if isSearching && titleMatches.isEmpty && messageMatches.isEmpty {
                            ContentUnavailableView.search(text: search)
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: ChatRoute.self) { ChatView(route: $0) }
            .onAppear(perform: openPending)
            .onChange(of: manager.pendingRoute) { _, _ in openPending() }
            .task(id: search) { await searchMessages() }
        }
    }

    private func route(for conversation: StoredConversation) -> ChatRoute {
        ChatRoute(account: conversation.account, peer: conversation.peer, kind: conversation.kind, title: conversation.title)
    }

    private func isTyping(_ conversation: StoredConversation) -> Bool {
        conversation.kind == .chat && manager.session(for: conversation.account)?.typingPeers.contains(conversation.peer) == true
    }

    private func conversationLink(_ conversation: StoredConversation) -> some View {
        NavigationLink(value: route(for: conversation)) {
            ConversationRow(conversation: conversation, isTyping: isTyping(conversation))
        }
        .swipeActions {
            Button(conversation.kind == .room ? "Leave" : "Delete", role: .destructive) {
                manager.deleteConversation(conversation)
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if !titleMatches.isEmpty {
            Section("Conversations") {
                ForEach(titleMatches) { conversationLink($0) }
            }
        }
        if !messageMatches.isEmpty {
            Section(messageMatches.count == Self.maxMessageMatches ? "Latest \(Self.maxMessageMatches) Messages" : "Messages") {
                ForEach(messageMatches) { message in
                    if let conversation = conversations.first(where: { $0.id == message.conversationID }) {
                        NavigationLink(value: route(for: conversation)) {
                            MessageMatchRow(message: message, conversation: conversation)
                        }
                    }
                }
            }
        }
    }

    /// Searches every message stored on this device. The pause avoids querying on
    /// each keystroke, and `.task(id:)` cancels it when the text changes again.
    private func searchMessages() async {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            messageMatches = []
            return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        var descriptor = FetchDescriptor<StoredMessage>(
            predicate: #Predicate<StoredMessage> { $0.body.localizedStandardContains(term) },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = Self.maxMessageMatches
        messageMatches = (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Opens the conversation from a tapped notification.
    private func openPending() {
        guard let route = manager.pendingRoute else { return }
        path = [route]
        manager.pendingRoute = nil
    }
}

private func shortDate(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(date: .numeric, time: .omitted)
}

private struct ConversationRow: View {
    let conversation: StoredConversation
    let isTyping: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(conversation.unread > 0 ? Color.blue : Color.clear)
                .frame(width: 9, height: 9)
                .accessibilityLabel(conversation.unread > 0 ? "\(conversation.unread) unread" : "")
            AvatarView(key: conversation.peer, name: conversation.title, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(verbatim: conversation.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    if conversation.lastTimestamp > .distantPast {
                        Text(verbatim: shortDate(conversation.lastTimestamp)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if isTyping {
                    Text("typing…")
                        .font(.subheadline.italic())
                        .foregroundStyle(.blue)
                        .lineLimit(2)
                } else {
                    Text(verbatim: conversation.lastBody)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct MessageMatchRow: View {
    let message: StoredMessage
    let conversation: StoredConversation

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(key: conversation.peer, name: conversation.title, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(verbatim: conversation.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    Text(verbatim: shortDate(message.timestamp)).font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: "\(message.outgoing ? "You" : message.sender): \(message.body)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
