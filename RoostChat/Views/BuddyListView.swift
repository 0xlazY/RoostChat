import RoostChatCore
import SwiftUI

/// The classic buddy list: contacts from every account, grouped, with presence.
struct BuddyListView: View {
    @EnvironmentObject private var manager: SessionManager
    @AppStorage("buddyList.showOffline") private var showOffline = true
    @State private var showingAddBuddy = false
    @State private var showingJoinRoom = false
    @State private var showingStatus = false
    @State private var buddyToRemove: Buddy?

    private var allBuddies: [Buddy] {
        manager.sessions.flatMap(\.buddies)
    }

    private var visibleBuddies: [Buddy] {
        showOffline ? allBuddies : allBuddies.filter { $0.availability != .offline }
    }

    private var groups: [BuddyGroup] {
        var byGroup = [String: [Buddy]]()
        for buddy in visibleBuddies {
            for group in buddy.groups.isEmpty ? ["Buddies"] : buddy.groups {
                byGroup[group, default: []].append(buddy)
            }
        }
        return byGroup.keys.sorted().map { name -> BuddyGroup in
            let sorted = (byGroup[name] ?? []).sorted { lhs, rhs in
                let lhsOnline = lhs.availability != .offline
                let rhsOnline = rhs.availability != .offline
                if lhsOnline != rhsOnline { return lhsOnline }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return BuddyGroup(name: name, buddies: sorted)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if manager.sessions.isEmpty {
                    ContentUnavailableView("No accounts", systemImage: "person.crop.circle.badge.plus",
                                           description: Text("Add an XMPP account in the Accounts tab."))
                } else {
                    buddyList
                }
            }
            .navigationTitle("Buddies")
            .navigationDestination(for: ChatRoute.self) { ChatView(route: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingStatus = true
                    } label: {
                        HStack(spacing: 6) {
                            AvailabilityDot(availability: manager.availability)
                            Text(manager.availability.label).font(.subheadline)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add Buddy", systemImage: "person.badge.plus") { showingAddBuddy = true }
                        Button("Join Room", systemImage: "number") { showingJoinRoom = true }
                        Toggle("Show Offline Buddies", isOn: $showOffline)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(manager.sessions.isEmpty)
                }
            }
            .sheet(isPresented: $showingAddBuddy) { AddBuddyView() }
            .sheet(isPresented: $showingJoinRoom) { JoinRoomView() }
            .sheet(isPresented: $showingStatus) { StatusView() }
        }
    }

    private var buddyList: some View {
        List {
            requests
            ForEach(groups) { group in
                Section(group.name) {
                    ForEach(group.buddies) { buddy in
                        NavigationLink(value: ChatRoute(account: buddy.account, peer: buddy.jid, kind: .chat, title: buddy.name)) {
                            BuddyRow(buddy: buddy, showAccount: manager.sessions.count > 1)
                        }
                        .swipeActions {
                            // Not role: .destructive, which animates the row away
                            // before the user has confirmed.
                            Button("Remove") { buddyToRemove = buddy }
                                .tint(.red)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Remove \(buddyToRemove?.name ?? "buddy")?",
                            isPresented: Binding(get: { buddyToRemove != nil }, set: { if !$0 { buddyToRemove = nil } }),
                            titleVisibility: .visible,
                            presenting: buddyToRemove) { buddy in
            Button("Remove Buddy", role: .destructive) {
                manager.session(for: buddy.account)?.removeBuddy(buddy.jid)
            }
        } message: { buddy in
            Text(verbatim: "\(buddy.jid) will be removed from your contact list on the server, on all your devices. Your conversation history stays.")
        }
    }

    @ViewBuilder
    private var requests: some View {
        ForEach(manager.sessions) { session in
            if !session.subscriptionRequests.isEmpty || !session.invites.isEmpty {
                Section("Requests for \(session.jid)") {
                    ForEach(session.subscriptionRequests, id: \.self) { address in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: address).font(.headline)
                            Text("Wants to add you and see when you're online.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Allow") { session.approveSubscription(address) }
                                    .buttonStyle(.borderedProminent)
                                Button("Deny", role: .destructive) { session.denySubscription(address) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    ForEach(session.invites) { invite in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: invite.room).font(.headline)
                            if let inviter = invite.inviter {
                                Text(verbatim: "Invited by \(inviter)").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Join") {
                                    let nick = session.jid.split(separator: "@").first.map(String.init) ?? "guest"
                                    session.joinRoom(address: invite.room, nickname: nick, password: invite.password)
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Ignore", role: .destructive) { session.declineInvite(invite) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct BuddyGroup: Identifiable {
    let name: String
    let buddies: [Buddy]

    var id: String { name }
}

private struct BuddyRow: View {
    let buddy: Buddy
    let showAccount: Bool

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(key: buddy.jid, name: buddy.name, size: 44)
                .overlay(alignment: .bottomTrailing) {
                    AvailabilityDot(availability: buddy.availability)
                        .padding(2)
                        .background(Color(.systemBackground), in: Circle())
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: buddy.name)
                    .foregroundStyle(buddy.availability == .offline ? .secondary : .primary)
                if buddy.awaitingApproval {
                    Text("Awaiting authorization").font(.caption).foregroundStyle(.secondary)
                } else if let status = buddy.statusText, !status.isEmpty {
                    Text(verbatim: status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if showAccount {
                    Text(verbatim: buddy.account).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct StatusView: View {
    @EnvironmentObject private var manager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var availability: Availability = .available
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Status", selection: $availability) {
                    ForEach(Availability.allCases.filter { $0 != .offline }) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
                TextField("Status message (optional)", text: $message)
            }
            .navigationTitle("Your Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        manager.setStatus(availability, message: message)
                        dismiss()
                    }
                }
            }
            .onAppear {
                availability = manager.availability
                message = manager.statusMessage
            }
        }
    }
}

/// Account picker shared by the add-buddy and join-room forms.
private struct AccountPicker: View {
    @EnvironmentObject private var manager: SessionManager
    @Binding var selection: String

    var body: some View {
        if manager.sessions.count > 1 {
            Picker("Account", selection: $selection) {
                ForEach(manager.sessions) { Text(verbatim: $0.jid).tag($0.jid) }
            }
        }
    }
}

struct AddBuddyView: View {
    @EnvironmentObject private var manager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var address = ""
    @State private var name = ""
    @State private var group = ""

    private var normalized: String? { Address.normalizedBare(address) }

    var body: some View {
        NavigationStack {
            Form {
                AccountPicker(selection: $account)
                TextField("Address (name@example.org)", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                TextField("Alias (optional)", text: $name)
                TextField("Group (optional)", text: $group)
            }
            .navigationTitle("Add Buddy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let normalized else { return }
                        manager.session(for: account)?.addBuddy(normalized, name: name.isEmpty ? nil : name, group: group.isEmpty ? nil : group)
                        dismiss()
                    }
                    .disabled(normalized == nil)
                }
            }
            .onAppear { account = manager.sessions.first?.jid ?? "" }
        }
    }
}

struct JoinRoomView: View {
    @EnvironmentObject private var manager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var address = ""
    @State private var nickname = ""
    @State private var password = ""

    private var normalized: String? { Address.normalizedBare(address) }

    var body: some View {
        NavigationStack {
            Form {
                AccountPicker(selection: $account)
                TextField("Room (room@conference.example.org)", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                TextField("Nickname", text: $nickname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Room password (optional)", text: $password)
            }
            .navigationTitle("Join Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") {
                        guard let normalized else { return }
                        manager.session(for: account)?.joinRoom(address: normalized, nickname: nickname, password: password.isEmpty ? nil : password)
                        dismiss()
                    }
                    .disabled(normalized == nil || nickname.isEmpty)
                }
            }
            .onAppear {
                account = manager.sessions.first?.jid ?? ""
                nickname = account.split(separator: "@").first.map(String.init) ?? ""
            }
        }
    }
}
