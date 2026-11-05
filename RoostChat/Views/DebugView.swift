import SwiftUI
import UIKit

/// App information and the live log. With `account` set, it starts filtered to
/// that account.
struct DebugView: View {
    let account: String?

    @EnvironmentObject private var manager: SessionManager
    @ObservedObject private var log = DebugLog.shared
    @AppStorage(AppSettings.logStream) private var logStream = true
    @AppStorage(AppSettings.logBodies) private var logBodies = false
    @State private var category: LogCategory?
    @State private var search = ""
    @State private var notificationStatus = "…"

    init(account: String? = nil) {
        self.account = account
    }

    private var filtered: [LogEntry] {
        log.entries.filter { entry in
            if let account, entry.account != account { return false }
            if let category, entry.category != category { return false }
            if !search.isEmpty, !entry.text.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }

    private var exportText: String {
        filtered.map(\.line).joined(separator: "\n")
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        List {
            if account == nil {
                Section("App") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("iOS", value: UIDevice.current.systemVersion)
                    LabeledContent("Device", value: UIDevice.current.model)
                    LabeledContent("Keep-alive", value: manager.keepAliveRunning ? "Running" : "Off")
                    LabeledContent("Notifications", value: notificationStatus)
                    Button("Send Test Notification") { manager.notifier.postTest() }
                }
                Section("Accounts") {
                    ForEach(manager.sessions) { session in
                        LabeledContent(session.jid, value: session.status.label)
                    }
                }
            }
            Section {
                Toggle("Log XML stream", isOn: $logStream)
                Toggle("Include message text", isOn: $logBodies)
                    .disabled(!logStream)
            } header: {
                Text("Logging")
            } footer: {
                Text("Logs stay in memory until the app closes. Passwords and login exchanges are always removed. Logs still show contacts and addresses, so check them before sharing.")
            }
            Section {
                Picker("Show", selection: $category) {
                    Text("All").tag(LogCategory?.none)
                    ForEach(LogCategory.allCases) { Text($0.rawValue).tag(LogCategory?.some($0)) }
                }
                .pickerStyle(.segmented)
                TextField("Search", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Copy \(filtered.count) Lines") { UIPasteboard.general.string = exportText }
                ShareLink("Share Log", item: exportText)
                Button("Clear", role: .destructive) { log.clear() }
            } header: {
                Text("Log")
            }
            Section {
                ForEach(filtered.suffix(500).reversed()) { entry in
                    Text(verbatim: entry.line)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text("Newest First (up to 500)")
            }
        }
        .navigationTitle(account ?? "Debug")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            manager.notifier.authorizationSummary { notificationStatus = $0 }
        }
    }
}
