import SwiftData
import SwiftUI

/// The conversation list, laid out like Messages.
struct ConversationListView: View {
    @EnvironmentObject private var manager: SessionManager
    @Query(sort: \StoredConversation.lastTimestamp, order: .reverse) private var conversations: [StoredConversation]
    @State private var path: [ChatRoute] = []
    @State private var search = ""

    private var filtered: [StoredConversation] {
        guard !search.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.lastBody.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if conversations.isEmpty {
                    ContentUnavailableView("No conversations", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Tap a buddy to start chatting."))
                } else {
                    List(filtered) { conversation in
                        NavigationLink(value: ChatRoute(account: conversation.account, peer: conversation.peer,
                                                        kind: conversation.kind, title: conversation.title)) {
                            ConversationRow(conversation: conversation)
                        }
                        .swipeActions {
                            Button(conversation.kind == .room ? "Leave" : "Delete", role: .destructive) {
                                manager.deleteConversation(conversation)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $search)
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: ChatRoute.self) { ChatView(route: $0) }
            .onAppear(perform: openPending)
            .onChange(of: manager.pendingRoute) { _, _ in openPending() }
        }
    }

    /// Opens the conversation from a tapped notification.
    private func openPending() {
        guard let route = manager.pendingRoute else { return }
        path = [route]
        manager.pendingRoute = nil
    }
}

private struct ConversationRow: View {
    let conversation: StoredConversation

    private var timeLabel: String {
        let date = conversation.lastTimestamp
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .numeric, time: .omitted)
    }

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
                        Text(verbatim: timeLabel).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: conversation.lastBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
