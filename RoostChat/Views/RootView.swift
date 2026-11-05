import SwiftData
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var manager: SessionManager
    @Query private var conversations: [StoredConversation]
    @State private var tab = Tab.buddies

    private enum Tab: Hashable {
        case buddies, chats, settings
    }

    private var unread: Int { conversations.reduce(0) { $0 + $1.unread } }

    var body: some View {
        TabView(selection: $tab) {
            BuddyListView()
                .tabItem { Label("Buddies", systemImage: "person.2") }
                .tag(Tab.buddies)
            ConversationListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .badge(unread)
                .tag(Tab.chats)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: manager.pendingRoute) { _, route in
            if route != nil { tab = .chats }
        }
    }
}

extension Availability {
    var color: Color {
        switch self {
        case .chat, .available: return .green
        case .away: return .yellow
        case .xa: return .orange
        case .dnd: return .red
        case .offline: return .gray
        }
    }
}

/// A profile picture with the contact's status in the corner, when it's known.
struct PresenceAvatar: View {
    let key: String
    let name: String
    let size: CGFloat
    let availability: Availability?

    var body: some View {
        AvatarView(key: key, name: name, size: size)
            .overlay(alignment: .bottomTrailing) {
                if let availability {
                    AvailabilityDot(availability: availability)
                        .padding(2)
                        .background(Color(.systemBackground), in: Circle())
                }
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
