import SwiftData
import SwiftUI

struct RootView: View {
    @Query private var conversations: [StoredConversation]

    private var unread: Int { conversations.reduce(0) { $0 + $1.unread } }

    var body: some View {
        TabView {
            BuddyListView()
                .tabItem { Label("Buddies", systemImage: "person.2") }
            ConversationListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .badge(unread)
            AccountsView()
                .tabItem { Label("Accounts", systemImage: "gearshape") }
        }
    }
}

extension Availability {
    var color: Color {
        switch self {
        case .available: return .green
        case .away: return .yellow
        case .xa: return .orange
        case .dnd: return .red
        case .offline: return .gray
        }
    }
}

struct AvailabilityDot: View {
    let availability: Availability

    var body: some View {
        Circle()
            .fill(availability.color)
            .frame(width: 10, height: 10)
            .accessibilityLabel(availability.label)
    }
}
