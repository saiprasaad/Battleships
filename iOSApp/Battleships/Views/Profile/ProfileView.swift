import BattleshipAPI
import BattleshipCore
import SwiftUI
import UIKit
import UserNotifications

/// The player's record, settings and account.
struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var showsSignIn = false
    @State private var confirmsSignOut = false
    @State private var confirmsDeletion = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var notificationStatus: UNAuthorizationStatus?

    var body: some View {
        NavigationStack {
            List {
                if let account = app.session.account {
                    Section {
                        ProfileHeader(account: account)
                    }
                    .listRowBackground(Color.clear)
                    Section {
                        HStack {
                            StatTile(title: "Wins", value: "\(account.stats.wins)")
                            StatTile(title: "Losses", value: "\(account.stats.losses)")
                            StatTile(
                                title: "Win Rate",
                                value: account.stats.winRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"
                            )
                        }
                        .padding(.vertical, 6)
                    } header: {
                        SheetSectionHeader(title: "Online Record")
                    }
                    .listRowBackground(Theme.rowBackground)
                } else if app.isSignedIn {
                    Section {
                        ProgressView()
                    }
                    .listRowBackground(Theme.rowBackground)
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Play online", systemImage: "person.2.wave.2.fill")
                                .font(.headline)
                            Text("Create a free account to challenge friends, get matched with other players and earn a rating.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Sign In or Create Account") { showsSignIn = true }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(Theme.rowBackground)
                }

                Section {
                    ForEach(Difficulty.allCases) { difficulty in
                        LabeledContent(difficulty.displayName) {
                            Text("\(app.solo.record.wins[difficulty] ?? 0)W · \(app.solo.record.losses[difficulty] ?? 0)L")
                                .monospacedDigit()
                        }
                    }
                } header: {
                    SheetSectionHeader(title: "Against the Computer")
                }
                .listRowBackground(Theme.rowBackground)

                Section {
                    Toggle(isOn: Bindable(app.settings).soundEnabled) {
                        Label("Sound Effects", systemImage: "speaker.wave.2.fill")
                    }
                    Toggle(isOn: Bindable(app.settings).hapticsEnabled) {
                        Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
                    }
                    notificationsRow
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        LabeledContent {
                            Text(app.settings.serverURL.host() ?? app.settings.serverURL.absoluteString)
                        } label: {
                            Label("Server", systemImage: "server.rack")
                        }
                    }
                } header: {
                    SheetSectionHeader(title: "Settings")
                }
                .listRowBackground(Theme.rowBackground)

                if app.isSignedIn {
                    Section {
                        NavigationLink {
                            BlockedPlayersView()
                        } label: {
                            Label("Blocked Players", systemImage: "hand.raised")
                        }
                        Button("Sign Out") { confirmsSignOut = true }
                    } header: {
                        SheetSectionHeader(title: "Account")
                    }
                    .listRowBackground(Theme.rowBackground)
                    Section {
                        Button(role: .destructive) {
                            confirmsDeletion = true
                        } label: {
                            if isDeleting {
                                ProgressView()
                            } else {
                                Text("Delete Account")
                            }
                        }
                        .disabled(isDeleting)
                    } footer: {
                        Text("Deleting your account removes your profile and rating. Battles in progress are resigned.")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .listRowBackground(Theme.rowBackground)
                }

                Section {
                    NavigationLink {
                        HowToPlayView()
                    } label: {
                        Label("How to Play", systemImage: "questionmark.circle")
                    }
                    Link(destination: app.privacyPolicyURL) {
                        Label("Privacy Policy", systemImage: "lock.shield")
                    }
                    Link(destination: app.termsURL) {
                        Label("Terms of Use", systemImage: "doc.text")
                    }
                    Link(destination: app.supportURL) {
                        Label("Support", systemImage: "lifepreserver")
                    }
                    LabeledContent("Version", value: Self.version)
                } header: {
                    SheetSectionHeader(title: "About")
                }
                .listRowBackground(Theme.rowBackground)
            }
            .scrollContentBackground(.hidden)
            .background { OceanBackdrop() }
            .navigationTitle("Profile")
            .refreshable { await app.session.refreshAccount() }
            .task { notificationStatus = await PushPermission.status() }
            .sheet(isPresented: $showsSignIn) { AuthSheet() }
            .confirmationDialog("Sign out?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task { await app.signOut() }
                }
            } message: {
                Text("Games against the computer stay on this device.")
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) { deleteAccount() }
            } message: {
                Text("This permanently deletes your account, rating and online history, and resigns your battles in progress. This can't be undone.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var notificationsRow: some View {
        switch notificationStatus {
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                LabeledContent {
                    Text("Off")
                } label: {
                    Label("Notifications", systemImage: "bell.slash")
                }
            }
            .foregroundStyle(.primary)
        case .notDetermined:
            Button {
                Task {
                    await PushPermission.request(settings: app.settings)
                    notificationStatus = await PushPermission.status()
                }
            } label: {
                LabeledContent {
                    Text("Turn On")
                        .foregroundStyle(.tint)
                } label: {
                    Label("Notifications", systemImage: "bell")
                }
            }
            .foregroundStyle(.primary)
        case .some:
            LabeledContent {
                Text("On")
            } label: {
                Label("Notifications", systemImage: "bell.badge")
            }
        case nil:
            EmptyView()
        }
    }

    private func deleteAccount() {
        isDeleting = true
        Task {
            do {
                try await app.deleteAccount()
            } catch {
                errorMessage = error.userMessage
            }
            isDeleting = false
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct ProfileHeader: View {
    let account: Account

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                SonarPing(tint: Theme.reticle)
                    .frame(width: 130, height: 130)
                OpponentAvatar(name: account.username, size: 84)
                    .overlay(Circle().strokeBorder(Theme.reticle.opacity(0.8), lineWidth: 2).padding(-4))
                    .glow(Theme.reticle, radius: 10)
            }
            .frame(height: 112)
            VStack(spacing: 4) {
                Text(account.username)
                    .displayFont(24, weight: .black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("Captain since \(account.createdAt.formatted(.dateTime.month(.wide).year()))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Label("\(account.stats.rating)", systemImage: "star.fill")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Theme.gold)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Theme.gold.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.4), lineWidth: 1))
                .accessibilityLabel("Rating \(account.stats.rating)")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Points the app at a different Battleships server, e.g. one you're running yourself.
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var confirmsSwitch = false
    @State private var isChecking = false
    @State private var checkResult: String?

    var body: some View {
        Form {
            Section {
                TextField("https://battleships.example.com", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                SheetSectionHeader(title: "Server address")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    // Save stays off for an address like this, so say why.
                    if let problem = AppSettings.serverAddressProblem(address) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.amber)
                    }
                    Text("Accounts belong to a server, so switching signs you out. Games against the computer are kept.")
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .listRowBackground(Theme.rowBackground)

            Section {
                Button("Test Connection") { testConnection() }
                    .disabled(parsedURL == nil || isChecking)
                if isChecking {
                    ProgressView()
                } else if let checkResult {
                    Text(checkResult)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Theme.rowBackground)

            if app.settings.serverURL != app.settings.defaultServerURL {
                Section {
                    Button("Use Default Server") {
                        address = app.settings.defaultServerURL.absoluteString
                    }
                }
                .listRowBackground(Theme.rowBackground)
            }
        }
        .scrollContentBackground(.hidden)
        .background { OceanBackdrop() }
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if app.isSignedIn {
                        confirmsSwitch = true
                    } else {
                        save()
                    }
                }
                .disabled(parsedURL == nil || parsedURL == app.settings.serverURL)
            }
        }
        .onAppear { address = app.settings.serverURL.absoluteString }
        .confirmationDialog("Switch servers?", isPresented: $confirmsSwitch, titleVisibility: .visible) {
            Button("Switch and Sign Out", role: .destructive) { save() }
        } message: {
            Text("You'll be signed out of your current account.")
        }
    }

    private var parsedURL: URL? {
        AppSettings.validatedServerURL(address)
    }

    private func save() {
        guard let url = parsedURL else { return }
        Task {
            await app.changeServer(to: url)
            dismiss()
        }
    }

    private func testConnection() {
        guard let url = parsedURL else { return }
        isChecking = true
        checkResult = nil
        Task {
            defer { isChecking = false }
            do {
                var request = URLRequest(url: url.appending(path: "health"))
                request.timeoutInterval = 8
                let (_, response) = try await URLSession.shared.data(for: request)
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                checkResult = ok ? "✓ Connected. The server is up." : "The server answered, but not like a Battleships server."
            } catch {
                checkResult = "Couldn't connect: \(error.localizedDescription)"
            }
        }
    }
}
