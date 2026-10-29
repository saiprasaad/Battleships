import BattleshipAPI
import BattleshipCore
import SwiftUI
import UIKit
import UserNotifications

/// The player's record, settings and account.
struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.motionPolicy) private var policy
    @State private var showsSignIn = false
    @State private var confirmsSignOut = false
    @State private var confirmsDeletion = false
    @State private var isDeleting = false
    @State private var notificationStatus: UNAuthorizationStatus?
    /// Bumped on each user flip of the Haptics toggle, to bounce its icon.
    @State private var hapticBounces = 0

    var body: some View {
        NavigationStack {
            List {
                if let account = app.session.account {
                    Section {
                        ProfileHeader(account: account, previousRating: app.session.previousRating, delta: app.session.ratingDelta)
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
                    // The cached account is on its way.
                    Section {
                        SonarLoader(captions: ["Hailing the fleet…"])
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        EmptySeaView(
                            title: "Play online",
                            message: "Create a free account to challenge friends, get matched with other players and earn a rating."
                        ) {
                            Button("Sign In or Create Account") {
                                app.feedback.play(.navigate)
                                showsSignIn = true
                            }
                            .primaryActionStyle()
                        }
                        .padding(.vertical, 6)
                        .staggeredEntrance(index: 0, trigger: app.isSignedIn)
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
                    Toggle(isOn: soundEffects) {
                        Label("Sound Effects", systemImage: "speaker.wave.2.fill")
                    }
                    Toggle(isOn: haptics) {
                        SettingsLabel(title: "Haptics", systemImage: "iphone.radiowaves.left.and.right", bounces: hapticBounces)
                    }
                    NavigationLink {
                        EffectsSettingsView()
                    } label: {
                        LabeledContent {
                            Text(app.settings.effectsLevel.displayName)
                        } label: {
                            Label("Effects", systemImage: "sparkles")
                        }
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
                            BusyLabel(title: "Delete Account", isBusy: isDeleting)
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
                        .contentShape(Rectangle())
                        // Five taps show the frame-time overlay, for testers.
                        .onTapGesture(count: 5) { togglePerformanceOverlay() }
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
            .task(id: app.session.ratingDelta) { await forgetShownRatingDelta() }
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

    // MARK: Toggles

    /// Sound Effects: a `.select` tick when switched on, and the ambient sea follows the setting.
    /// Only a user's flip comes through here; a setting changed elsewhere stays silent.
    private var soundEffects: Binding<Bool> {
        Binding(
            get: { app.settings.soundEnabled },
            set: { isOn in
                app.settings.soundEnabled = isOn
                app.ambienceSettingDidChange()
                if isOn {
                    app.feedback.play(.select)
                }
            }
        )
    }

    /// Haptics: a `.place` thump to feel, with the row's icon bouncing, on a user's flip.
    private var haptics: Binding<Bool> {
        Binding(
            get: { app.settings.hapticsEnabled },
            set: { isOn in
                app.settings.hapticsEnabled = isOn
                app.feedback.play(.place)
                if policy.tier == .full {
                    hapticBounces += 1
                }
            }
        )
    }

    // MARK: The rating change

    /// Leaves the last rating change on screen for a while, then lets the session forget it.
    private func forgetShownRatingDelta() async {
        guard app.session.ratingDelta != nil else { return }
        try? await Task.sleep(for: .seconds(ProfileBeat.deltaHold))
        guard !Task.isCancelled else { return }
        app.session.clearRatingDelta()
    }

    // MARK: The performance overlay

    /// The frame-time overlay is for development and TestFlight builds; an App Store build keeps
    /// no hidden gesture.
    private static var allowsPerformanceOverlay: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    private func togglePerformanceOverlay() {
        guard Self.allowsPerformanceOverlay else { return }
        app.settings.showsPerformanceOverlay.toggle()
        app.feedback.play(.select)
        ToastCenter.shared.show(.info, app.settings.showsPerformanceOverlay ? "Performance overlay on." : "Performance overlay off.")
    }

    private func deleteAccount() {
        isDeleting = true
        Task {
            do {
                try await app.deleteAccount()
            } catch {
                ToastCenter.shared.show(.error, error.userMessage)
                app.feedback.play(.toastError)
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

/// The profile's own beats, in seconds: how long the old rating is held before it rolls to the new
/// one, and how long the rating change stays on screen before the session forgets it.
private enum ProfileBeat {
    static let ratingHold: TimeInterval = 0.6
    static let deltaHold: TimeInterval = 3
}

/// The avatar in its sonar ring and rating ring, the name, and the rating pill. After an online game
/// the pill holds the old rating for a beat, then rolls to the new one (`rollingNumber`) with a
/// `DeltaChip` floating beside it and the pill glowing in the change's colour; VoiceOver hears
/// "Rating up 12" once and reads the change in the pill's value while it shows.
private struct ProfileHeader: View {
    let account: Account
    /// The rating before the last online game, while its change is still to be shown.
    let previousRating: Int?
    /// What the last online game did to the rating, while it is still to be shown.
    let delta: Int?

    @Environment(\.motionPolicy) private var policy
    @ScaledMetric(relativeTo: .largeTitle) private var avatarSize: CGFloat = 84
    /// The old rating, while the pill still shows it; nil once it shows the account's.
    @State private var heldRating: Int?

    private var rating: Int {
        heldRating ?? account.stats.rating
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                SonarPing(tint: Theme.reticle)
                    .frame(width: avatarSize * 1.55, height: avatarSize * 1.55)
                RatingRing(rating: account.stats.rating, wins: account.stats.wins, losses: account.stats.losses, diameter: avatarSize)
                OpponentAvatar(name: account.username, size: avatarSize)
                    .overlay(Circle().strokeBorder(Theme.reticle.opacity(0.8), lineWidth: 2).padding(-4))
                    .glow(Theme.reticle, radius: 10)
            }
            .frame(height: avatarSize + 28)
            VStack(spacing: 4) {
                Text(account.username)
                    .displayFont(24, weight: .black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("Captain since \(account.createdAt.formatted(.dateTime.month(.wide).year()))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ratingPill
                if let delta {
                    DeltaChip(delta: delta, trigger: delta)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .onChange(of: delta, initial: true) { holdOldRating() }
        .task(id: delta) { await rollToNewRating() }
    }

    private var ratingPill: some View {
        let tint: Color = delta.map { $0 >= 0 ? Theme.victory : Theme.hit } ?? Theme.gold
        return Label {
            Text("\(rating)")
                .rollingNumber(rating)
        } icon: {
            Image(systemName: "star.fill")
        }
        .font(.headline.monospacedDigit())
        .foregroundStyle(Theme.gold)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.gold.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.4), lineWidth: 1))
        .glow(tint, radius: delta == nil ? 0 : 10)
        .animation(Motion.Curve.fade.policy(policy), value: delta == nil)
        .accessibilityLabel(ratingLabel)
    }

    /// "Rating 1,184, up 12, 16 points to 1,200, 23 wins, 9 losses".
    private var ratingLabel: String {
        let stats = account.stats
        var parts = ["Rating \(stats.rating.formatted())"]
        if let delta, delta != 0 {
            parts.append(delta > 0 ? "up \(delta)" : "down \(-delta)")
        }
        parts.append("\(RatingRing.pointsToNext(from: stats.rating)) points to \(RatingRing.nextHundred(above: stats.rating).formatted())")
        parts.append(Phrase.count(stats.wins, "win"))
        parts.append("\(stats.losses) \(stats.losses == 1 ? "loss" : "losses")")
        return parts.joined(separator: ", ")
    }

    /// Shows the old rating first, without animating, and says what changed. Runs as the change
    /// arrives, and on appearance if one is waiting.
    private func holdOldRating() {
        guard let previousRating, let delta, delta != 0, previousRating != account.stats.rating else {
            heldRating = nil
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            heldRating = previousRating
        }
        AccessibilityNotification.Announcement(delta > 0 ? "Rating up \(delta)" : "Rating down \(-delta)").post()
    }

    /// A beat later the pill rolls to the account's rating on `Motion.Curve.counter`.
    private func rollToNewRating() async {
        guard delta != nil else { return }
        try? await Task.sleep(for: .seconds(policy.duration(ProfileBeat.ratingHold)))
        guard !Task.isCancelled else { return }
        heldRating = nil
    }
}

/// Points the app at a different Battleships server, e.g. one you're running yourself.
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var confirmsSwitch = false
    @State private var isChecking = false

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
                Button {
                    testConnection()
                } label: {
                    BusyLabel(title: "Test Connection", isBusy: isChecking)
                }
                .disabled(parsedURL == nil || isChecking)
            } footer: {
                Text("The result shows at the top of the screen.")
                    .foregroundStyle(Theme.secondaryText)
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
        .onAppear {
            address = app.settings.serverURL.absoluteString
            app.feedback.play(.navigate)
        }
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

    /// Asks the server for its health and says what came back as a toast: news, not a decision.
    private func testConnection() {
        guard let url = parsedURL else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                var request = URLRequest(url: url.appending(path: "health"))
                request.timeoutInterval = 8
                let (_, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    ToastCenter.shared.show(.success, "Connected. The server is up.")
                    app.feedback.play(.toastSuccess)
                } else {
                    ToastCenter.shared.show(.warning, "The server answered, but not like a Battleships server.")
                    app.feedback.play(.toastError)
                }
            } catch {
                ToastCenter.shared.show(.error, "Couldn't connect: \(error.localizedDescription)")
                app.feedback.play(.toastError)
            }
        }
    }
}
