import RoostChatCore
import SwiftUI

/// The Settings tab: accounts, app behaviour and debugging.
struct SettingsView: View {
    @EnvironmentObject private var manager: SessionManager
    #if SILENT_AUDIO
    @AppStorage(AppSettings.keepAlive) private var keepAlive = false
    #endif
    @AppStorage(AppSettings.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(AppSettings.notificationPreview) private var notificationPreview = true
    @AppStorage(AppSettings.notificationRooms) private var notificationRooms = RoomNotificationMode.mentions.rawValue
    @AppStorage(AppSettings.autoFetchMedia) private var autoFetchMedia = false
    @State private var showingAdd = false
    @State private var relayDraft = ""
    @State private var relayProblem: String?

    var body: some View {
        NavigationStack {
            List {
                Section("XMPP Accounts") {
                    if manager.sessions.isEmpty {
                        Text("No accounts yet.").foregroundStyle(.secondary)
                    }
                    ForEach(manager.sessions) { session in
                        NavigationLink {
                            AccountDetailView(session: session)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(key: session.jid, name: session.jid, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: session.jid)
                                    Text(verbatim: session.status.label)
                                        .font(.caption)
                                        .foregroundStyle(statusColor(session.status))
                                        .lineLimit(2)
                                    if let resource = session.assignedResource {
                                        Text(verbatim: "Resource: \(resource)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                #if SILENT_AUDIO
                Section {
                    Toggle("Stay connected using silent audio", isOn: $keepAlive)
                        .onChange(of: keepAlive) { _, _ in manager.updateKeepAlive() }
                } header: {
                    Text("Background")
                } footer: {
                    Text("Warning: this plays silent audio all the time so that iOS doesn't suspend the app. It uses noticeably more battery, phone calls can interrupt it, and it stops if the app is closed. Off, iOS suspends the app shortly after you leave it: your status doesn't change, but contacts see you offline once the server's time limit ends, and notifications stop until you return.")
                }
                #endif
                Section("Notifications") {
                    Toggle("Message notifications", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { _, enabled in
                            if enabled { manager.notifier.requestAuthorization() }
                        }
                    Toggle("Show message text", isOn: $notificationPreview)
                        .disabled(!notificationsEnabled)
                    Picker("Rooms", selection: $notificationRooms) {
                        Text("All messages").tag(RoomNotificationMode.all.rawValue)
                        Text("Mentions of my nickname").tag(RoomNotificationMode.mentions.rawValue)
                        Text("Off").tag(RoomNotificationMode.off.rawValue)
                    }
                    .disabled(!notificationsEnabled)
                }
                Section {
                    TextField("push.example.com", text: $relayDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Save Relay") {
                        relayProblem = manager.setPushRelay(relayDraft) ? nil : "That isn't a valid domain."
                    }
                    if let problem = relayProblem ?? manager.pushProblem {
                        Text(verbatim: problem).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Push Relay")
                } footer: {
                    Text("Shows \"New Message\" when the app is suspended, through a relay you host. Your XMPP server and the relay learn this device's push token, and message text isn't sent. Leave blank to turn it off. Each account's diagnostics show its status.")
                }
                Section {
                    Toggle("Fetch images automatically", isOn: $autoFetchMedia)
                } header: {
                    Text("Media")
                } footer: {
                    Text("When on, images load as soon as they appear, which reveals your IP address to the server hosting them. When off, tap an image to load it.")
                }
                Section("About") {
                    NavigationLink("Debug") { DebugView() }
                    LabeledContent("Encryption", value: "TLS to server only")
                    LabeledContent("Licence", value: "AGPL-3.0")
                    if let source = URL(string: "https://github.com/0xlazY/RoostChat") {
                        Link("Source code", destination: source)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Add Account", systemImage: "plus") { showingAdd = true }
            }
            .sheet(isPresented: $showingAdd) { AddAccountView() }
            .onAppear { relayDraft = manager.pushRelay ?? "" }
        }
    }

    private func statusColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .online: return .green
        case .failed: return .red
        case .connecting, .offline: return .secondary
        }
    }
}

/// Server, resource and certificate options, shared by adding and editing.
private struct ConnectionSettingsFields: View {
    @Binding var settings: AccountConnectionSettings

    var body: some View {
        Section {
            TextField("Server host (blank to use DNS)", text: $settings.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Port (blank for default)", text: $settings.port)
                .keyboardType(.numberPad)
            Toggle("Direct TLS", isOn: $settings.directTLS)
        } header: {
            Text("Server")
        } footer: {
            Text("Direct TLS encrypts from the first byte, usually on port 5223. Otherwise STARTTLS is used, usually on 5222. Both apply only with a custom host. Connections without TLS are never allowed.")
        }
        Section {
            TextField("Resource (blank for server-assigned)", text: $settings.resource)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Resource")
        } footer: {
            Text("The name this device announces. Contacts and servers can see it. The server may still assign a different one.")
        }
        Section {
            Toggle("Allow unverified certificate", isOn: $settings.allowUnverifiedTLS)
        } header: {
            Text("Certificate")
        } footer: {
            Text("For servers with self-signed or mismatched certificates. The first certificate seen is trusted and remembered, and a later change blocks the connection. If someone intercepts that first connection, they could get your login, so only enable this on a network you trust.")
        }
    }
}

struct AddAccountView: View {
    @EnvironmentObject private var manager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var password = ""
    @State private var settings = AccountConnectionSettings()
    @State private var problem: String?

    private var normalized: String? { Address.normalizedBare(address) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address (name@example.org)", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("Your password is stored in the iOS Keychain on this device only.")
                }
                ConnectionSettingsFields(settings: $settings)
                if let problem {
                    Text(verbatim: problem).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let normalized else { return }
                        if let error = manager.addAccount(jid: normalized, password: password, settings: settings) {
                            problem = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(normalized == nil || password.isEmpty || !settings.isValid)
                }
            }
        }
    }
}

struct AccountDetailView: View {
    let session: AccountSession

    @EnvironmentObject private var manager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var connectOnLaunch = true
    @State private var settings = AccountConnectionSettings()
    @State private var newPassword = ""
    @State private var confirmingRemoval = false
    @State private var loaded = false

    private var isOnline: Bool { session.status == .online || session.status == .connecting }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AvatarView(key: session.jid, name: session.jid, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: session.jid).font(.headline)
                        Text(verbatim: session.status.label).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Connection") {
                LabeledContent("Assigned resource", value: session.assignedResource ?? "Not connected")
                if isOnline {
                    Button("Disconnect") { manager.disconnect(jid: session.jid) }
                } else {
                    Button("Connect") { manager.connect(jid: session.jid) }
                }
                Toggle("Connect when app launches", isOn: $connectOnLaunch)
                    .onChange(of: connectOnLaunch) { _, value in
                        manager.setConnectOnLaunch(value, jid: session.jid)
                    }
            }
            Section("Diagnostics") {
                if session.diagnostics.rows.isEmpty {
                    Text("Nothing yet. Try connecting.").foregroundStyle(.secondary)
                }
                ForEach(session.diagnostics.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.label).font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: row.value).font(.footnote).textSelection(.enabled)
                    }
                }
                Button("Ping Server") { session.measurePing() }
                Button("Copy Report") { UIPasteboard.general.string = report }
                NavigationLink("Server Capabilities") { CapabilitiesView(session: session) }
                NavigationLink("Debug Logs") { DebugView(account: session.jid) }
            }
            ConnectionSettingsFields(settings: $settings)
            Section {
                Button("Save and Reconnect") {
                    manager.saveConnectionSettings(settings, jid: session.jid)
                }
                .disabled(!settings.isValid)
                if manager.account(session.jid)?.pinnedCertificate != nil {
                    Button("Forget Accepted Certificate", role: .destructive) {
                        manager.forgetPinnedCertificate(jid: session.jid)
                    }
                }
            }
            Section {
                SecureField("New password", text: $newPassword)
                    .textContentType(.password)
                Button("Save Password and Reconnect") {
                    manager.updatePassword(jid: session.jid, password: newPassword)
                    newPassword = ""
                }
                .disabled(newPassword.isEmpty)
            } header: {
                Text("Change Stored Password")
            } footer: {
                Text("Stored in the iOS Keychain on this device only. This doesn't change the password on the server.")
            }
            Section {
                Button("Remove Account", role: .destructive) { confirmingRemoval = true }
            } footer: {
                Text("Deletes this account's messages and password from this device. The account on the server is not affected.")
            }
        }
        .navigationTitle(session.jid)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            connectOnLaunch = manager.account(session.jid)?.enabled ?? true
            settings = manager.connectionSettings(for: session.jid)
        }
        .confirmationDialog("Remove \(session.jid)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Account", role: .destructive) {
                manager.removeAccount(jid: session.jid)
                dismiss()
            }
        }
    }

    private var report: String {
        "Account: \(session.jid)\nStatus: \(session.status.label)\n\(session.diagnostics.report)"
    }
}
