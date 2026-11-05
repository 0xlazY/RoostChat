import SwiftData
import SwiftUI

@main
struct RoostChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @StateObject private var manager: SessionManager
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: StoredAccount.self, StoredRoom.self, StoredConversation.self, StoredMessage.self)
        } catch {
            fatalError("Could not open the message database: \(error)")
        }
        self.container = container
        _manager = StateObject(wrappedValue: SessionManager(store: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(manager)
                .task { manager.start() }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: manager.enterForeground()
            case .background: manager.enterBackground()
            default: break
            }
        }
    }
}
