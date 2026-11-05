import RoostChatCore
import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var manager: SessionManager
    @State private var showingAdd = false

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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: session.jid)
                                Text(verbatim: session.status.label)
                                    .font(.caption)
                                    .foregroundStyle(statusColor(session.status))
                            }
                        }
                    }
                }
                Section("About") {
                    LabeledContent("Encryption", value: "TLS to server only")
                    LabeledContent("Licence", value: "AGPL-3.0")
                    if let source = URL(string: "https://github.com/0xlazY/RoostChat") {
                        Link("Source code", destination: source)
                    }
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                Button("Add Account", systemImage: "plus") { showingAdd = true }
            }
            .sheet(isPresented: $showingAdd) { AddAccountView() }
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

struct AddAccountView: View {
    @EnvironmentObject private var manager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var password = ""
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
                    Text("The server is found through its DNS records. Connections require a valid TLS certificate.")
                }
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
                        if let error = manager.addAccount(jid: normalized, password: password) {
                            problem = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(normalized == nil || password.isEmpty)
                }
            }
        }
    }
}

struct AccountDetailView: View {
    let session: AccountSession

    @EnvironmentObject private var manager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = true
    @State private var newPassword = ""
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            Section("Status") {
                Text(verbatim: session.status.label)
                Toggle("Enabled", isOn: $enabled)
                    .onChange(of: enabled) { _, value in
                        manager.setEnabled(value, jid: session.jid)
                    }
            }
            Section("Change Stored Password") {
                SecureField("New password", text: $newPassword)
                    .textContentType(.password)
                Button("Save and Reconnect") {
                    manager.updatePassword(jid: session.jid, password: newPassword)
                    newPassword = ""
                }
                .disabled(newPassword.isEmpty)
            }
            Section {
                Button("Remove Account", role: .destructive) { confirmingRemoval = true }
            } footer: {
                Text("Deletes this account's messages and password from this device. The account on the server is not affected.")
            }
        }
        .navigationTitle(session.jid)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { enabled = manager.account(session.jid)?.enabled ?? true }
        .confirmationDialog("Remove \(session.jid)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Account", role: .destructive) {
                manager.removeAccount(jid: session.jid)
                dismiss()
            }
        }
    }
}
