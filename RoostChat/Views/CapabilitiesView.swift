import RoostChatCore
import SwiftUI

/// XMPP features: what a server advertises, and what this app implements. With
/// no session it shows only the app's side.
struct CapabilitiesView: View {
    let session: AccountSession?

    init(session: AccountSession?) {
        self.session = session
    }

    var body: some View {
        List {
            if let session {
                serverSections(session)
            }
            Section {
                ForEach(XEPCatalog.appSupported) { entry in
                    EntryRow(entry: entry)
                }
            } header: {
                Text("Implemented by RoostChat")
            }
            Section {
                ForEach(XEPCatalog.notImplemented) { entry in
                    EntryRow(entry: entry)
                }
            } header: {
                Text("Not Implemented Yet")
            }
        }
        .navigationTitle(session == nil ? "XMPP Features" : "Capabilities")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func serverSections(_ session: AccountSession) -> some View {
        let capabilities = session.capabilities
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
}

private struct FeatureRow: View {
    let namespace: String

    var body: some View {
        let entry = XEPCatalog.entry(forNamespace: namespace)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let entry {
                    Text(verbatim: "\(entry.spec): \(entry.name)").font(.footnote)
                }
                Text(verbatim: namespace)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if entry?.usedByApp == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Used by RoostChat")
            }
        }
    }
}

private struct EntryRow: View {
    let entry: XEPEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(entry.spec): \(entry.name)").font(.footnote)
            if let note = entry.appNote {
                Text(verbatim: note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
