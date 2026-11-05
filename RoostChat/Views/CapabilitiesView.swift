import RoostChatCore
import SwiftUI

/// What an account's server advertises about itself.
struct CapabilitiesView: View {
    let session: AccountSession

    @EnvironmentObject private var manager: SessionManager

    init(session: AccountSession) {
        self.session = session
    }

    private var capabilities: ServerCapabilities { session.capabilities }

    var body: some View {
        List {
            if capabilities.isEmpty {
                Section {
                    Text("Connect this account to read its server's capabilities.").foregroundStyle(.secondary)
                }
            }
            if !capabilities.identities.isEmpty {
                Section("Server Identity") {
                    ForEach(capabilities.identities, id: \.self) { Text(verbatim: $0).font(.footnote) }
                }
            }
            if !capabilities.saslMechanisms.isEmpty {
                Section("Login Mechanisms") {
                    ForEach(capabilities.saslMechanisms, id: \.self) { Text(verbatim: $0).font(.footnote) }
                }
            }
            if !capabilities.streamFeatures.isEmpty {
                Section("Stream Features") {
                    ForEach(capabilities.streamFeatures, id: \.self) { Text(verbatim: $0).font(.footnote) }
                }
            }
            if !capabilities.serverFeatures.isEmpty {
                Section("Server Features (\(capabilities.serverFeatures.count))") {
                    ForEach(capabilities.serverFeatures, id: \.self) { FeatureRow(namespace: $0) }
                }
            }
            if !capabilities.accountFeatures.isEmpty {
                Section("Account Features (\(capabilities.accountFeatures.count))") {
                    ForEach(capabilities.accountFeatures, id: \.self) { FeatureRow(namespace: $0) }
                }
            }
        }
        .navigationTitle("Server Capabilities")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FeatureRow: View {
    let namespace: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let entry = XEPCatalog.entry(forNamespace: namespace) {
                Text(verbatim: "\(entry.spec): \(entry.name)").font(.footnote)
            }
            Text(verbatim: namespace)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
