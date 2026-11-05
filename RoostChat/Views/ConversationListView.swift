import SwiftData
import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var manager: SessionManager
    @Query(sort: \StoredConversation.lastTimestamp, order: .reverse) private var conversations: [StoredConversation]
    @State private var path: [ChatRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if conversations.isEmpty {
                    ContentUnavailableView("No conversations", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Tap a buddy to start chatting."))
                } else {
                    List(conversations) { conversation in
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
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: ChatRoute.self) { ChatView(route: $0) }
            .onAppear(perform: openPending)
            .onChange(of: manager.pendingRoute) { _, _ in openPending() }
        }
    }
}

private extension ConversationListView {
    /// Opens the conversation from a tapped notification.
    func openPending() {
        guard let route = manager.pendingRoute else { return }
        path = [route]
        manager.pendingRoute = nil
    }
}

private struct ConversationRow: View {
    let conversation: StoredConversation

    private var icon: String {
        switch conversation.kind {
        case .chat: return "person"
        case .room: return "number"
        case .roomPrivate: return "lock"
        }
    }

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(verbatim: conversation.title)
                        .fontWeight(conversation.unread > 0 ? .bold : .regular)
                        .lineLimit(1)
                    Spacer()
                    if conversation.lastTimestamp > .distantPast {
                        Text(conversation.lastTimestamp, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(verbatim: conversation.lastBody)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if conversation.unread > 0 {
                        Text("\(conversation.unread)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }
}
