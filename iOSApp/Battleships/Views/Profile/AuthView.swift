import AuthenticationServices
import BattleshipAPI
import BattleshipClient
import SwiftUI

/// Sign in or create an account, presented as a sheet.
struct AuthSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AuthForm { dismiss() }
                .navigationTitle("Battleships Account")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
    }
}

struct AuthForm: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign In"
        case register = "Create Account"

        var id: String { rawValue }
    }

    private enum Field {
        case username, password, newUsername
    }

    /// A first sign-in with Apple or Google, waiting for the player to choose a username.
    private struct PendingSignup {
        let ticket: String
        let provider: String
    }

    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var mode: Mode = .signIn
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var appleNonce: String?
    @State private var signup: PendingSignup?
    @State private var chosenUsername = ""
    @FocusState private var focus: Field?
    var onSuccess: @MainActor () -> Void = {}

    var body: some View {
        Form {
            header

            if let signup {
                chooseUsername(for: signup)
            } else {
                if offersApple {
                    quickSignIn
                }
                usernameAndPassword
            }
        }
        .scrollContentBackground(.hidden)
        .background { OceanBackdrop() }
        .animation(.default, value: signup == nil)
        .onChange(of: mode) { errorMessage = nil }
        .task { await app.session.loadProviders() }
    }

    // MARK: Sections

    private var header: some View {
        Section {
            VStack(spacing: 10) {
                ZStack {
                    SonarPing()
                        .frame(width: 130, height: 130)
                    Image(systemName: "scope")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Theme.reticle)
                        .glow(Theme.reticle, radius: 10)
                        .accessibilityHidden(true)
                }
                .frame(height: 104)
                .accessibilityHidden(true)
                Text(title)
                    .font(.display(22, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        } footer: {
            agreement
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .listRowBackground(Color.clear)
    }

    /// Players agree to the terms, which don't tolerate abuse, before they can sign in (App Store
    /// guideline 1.2 asks this of apps where players see each other's content: here, usernames).
    private var agreement: Text {
        let markdown = "By continuing, you agree to the [Terms of Use](\(app.termsURL.absoluteString)) "
            + "and [Privacy Policy](\(app.privacyPolicyURL.absoluteString))."
        guard let text = try? AttributedString(markdown: markdown) else {
            return Text("By continuing, you agree to the Terms of Use and Privacy Policy.")
        }
        return Text(text)
    }

    private var title: String {
        if signup != nil { return "One last thing" }
        return mode == .signIn ? "Welcome back, Captain" : "Join the fleet"
    }

    private var subtitle: String {
        if signup != nil { return "Pick the name other captains will know you by." }
        return "An account lets you battle other players and earn a rating."
    }

    /// Sign in with Apple, and with Google when the server offers it. App Store guideline 4.8 asks
    /// for Sign in with Apple wherever another company's sign-in is offered, so Google only appears
    /// alongside it.
    private var quickSignIn: some View {
        Section {
            VStack(spacing: 12) {
                SignInWithAppleButton(.continue) { request in
                    let nonce = AppleSignIn.makeNonce()
                    appleNonce = nonce
                    AppleSignIn.prepare(request, nonce: nonce)
                } onCompletion: { result in
                    finishAppleSignIn(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .clipShape(.rect(cornerRadius: 12))

                if let googleClientID = app.session.providers.googleClientID {
                    Button {
                        signInWithGoogle(clientID: googleClientID)
                    } label: {
                        GoogleButtonLabel()
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(isWorking)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } footer: {
            Text("Battleships doesn't get your name or email this way, just a way to recognise you. You'll choose a username.")
        }
    }

    private var usernameAndPassword: some View {
        Group {
            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                if offersApple {
                    Text("Or use a username and password")
                }
            }

            Section {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .textContentType(mode == .signIn ? .password : .newPassword)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { submit() }
            } footer: {
                if mode == .register {
                    Text("Usernames are 3–20 letters, numbers or underscores. Passwords need at least 8 characters.")
                }
            }
            .listRowBackground(Theme.rowBackground)

            if let problem = validationProblem ?? errorMessage {
                problemSection(problem)
            }

            Section {
                Button { submit() } label: {
                    progressLabel(mode.rawValue)
                }
                .disabled(!canSubmit)
            } footer: {
                Text("Server: \(app.settings.serverURL.host() ?? app.settings.serverURL.absoluteString)")
            }
            .listRowBackground(Theme.rowBackground)
        }
    }

    @ViewBuilder
    private func chooseUsername(for signup: PendingSignup) -> some View {
        Section {
            TextField("Username", text: $chosenUsername)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .newUsername)
                .submitLabel(.done)
                .onSubmit { completeSignup(signup) }
        } header: {
            Text("Your username")
        } footer: {
            Text("You're signed in with \(signup.provider). Usernames are 3–20 letters, numbers or underscores, and everyone can see them.")
        }
        .listRowBackground(Theme.rowBackground)

        if let problem = signupProblem ?? errorMessage {
            problemSection(problem)
        }

        Section {
            Button { completeSignup(signup) } label: {
                progressLabel("Create Account")
            }
            .disabled(!canCompleteSignup)
            Button("Cancel", role: .cancel) {
                self.signup = nil
                errorMessage = nil
            }
            .disabled(isWorking)
        }
        .listRowBackground(Theme.rowBackground)
    }

    private func problemSection(_ problem: String) -> some View {
        Section {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        .listRowBackground(Theme.rowBackground)
    }

    private func progressLabel(_ title: String) -> some View {
        HStack {
            Spacer()
            if isWorking {
                ProgressView()
            } else {
                Text(title)
                    .bold()
            }
            Spacer()
        }
    }

    // MARK: Username and password

    private var offersApple: Bool {
        app.session.providers.apple
    }

    /// Problems worth showing before the server is even asked (only when creating an account).
    private var validationProblem: String? {
        guard mode == .register else { return nil }
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let problem = CredentialPolicy.usernameProblem(trimmed) {
            return problem
        }
        if !password.isEmpty, let problem = CredentialPolicy.passwordProblem(password) {
            return problem
        }
        return nil
    }

    private var canSubmit: Bool {
        !isWorking
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && validationProblem == nil
    }

    private func submit() {
        guard canSubmit else { return }
        let name = username.trimmingCharacters(in: .whitespaces)
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                switch mode {
                case .signIn:
                    try await app.signIn(username: name, password: password)
                case .register:
                    try await app.register(username: name, password: password)
                }
                app.feedback.play(.place)
                onSuccess()
            } catch {
                show(error.userMessage)
            }
        }
    }

    // MARK: Apple and Google

    private func finishAppleSignIn(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case let .success(authorization):
            guard let nonce = appleNonce else { return }
            do {
                let (request, appleUserID) = try AppleSignIn.signInRequest(from: authorization, nonce: nonce)
                continueSignIn(with: "Apple") {
                    try await app.signInWithApple(request, appleUserID: appleUserID)
                }
            } catch {
                show(error.userMessage)
            }
        case let .failure(error):
            guard !AppleSignIn.isCancellation(error) else { return }
            show(AppleSignIn.message(for: error))
        }
    }

    private func signInWithGoogle(clientID: String) {
        let session = webAuthenticationSession
        continueSignIn(with: "Google") {
            let request = try await GoogleSignIn(clientID: clientID).signIn(using: session)
            return try await app.signInWithGoogle(request)
        }
    }

    private func continueSignIn(with provider: String, _ attempt: @escaping @MainActor () async throws -> ExternalSignInOutcome) {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                switch try await attempt() {
                case .signedIn:
                    app.feedback.play(.place)
                    onSuccess()
                case let .needsUsername(ticket, suggestion):
                    chosenUsername = suggestion ?? ""
                    signup = PendingSignup(ticket: ticket, provider: provider)
                    focus = .newUsername
                }
            } catch is CancellationError {
                // The player backed out of the sign-in sheet.
            } catch {
                show(error.userMessage)
            }
        }
    }

    private var signupProblem: String? {
        let trimmed = chosenUsername.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return CredentialPolicy.usernameProblem(trimmed)
    }

    private var canCompleteSignup: Bool {
        !isWorking && !chosenUsername.trimmingCharacters(in: .whitespaces).isEmpty && signupProblem == nil
    }

    private func completeSignup(_ signup: PendingSignup) {
        guard canCompleteSignup else { return }
        let name = chosenUsername.trimmingCharacters(in: .whitespaces)
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await app.completeSignup(ticket: signup.ticket, username: name)
                app.feedback.play(.place)
                onSuccess()
            } catch let error as APIError where error.code == .signupTicketInvalid {
                self.signup = nil
                show("That took a little too long. Please continue with \(signup.provider) again.")
            } catch {
                show(error.userMessage)
            }
        }
    }

    private func show(_ message: String) {
        errorMessage = message
        app.feedback.play(.invalid)
    }
}

/// Google's "Continue with Google" button in its light style, following Google's branding
/// guidelines: the full-colour "G", dark grey text, a thin grey outline.
private struct GoogleButtonLabel: View {
    var body: some View {
        HStack(spacing: 10) {
            GoogleLogo()
                .frame(width: 20, height: 20)
            Text("Continue with Google")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color(red: 0.122, green: 0.122, blue: 0.122))
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(.white, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(red: 0.455, green: 0.467, blue: 0.459), lineWidth: 1)
        }
        .contentShape(.rect(cornerRadius: 12))
    }
}

/// Google's "G", from the paths of Google's own artwork (drawn on a 48-point grid).
private struct GoogleLogo: View {
    var body: some View {
        ZStack {
            GoogleLogoPart(part: .red).fill(Color(red: 0.918, green: 0.263, blue: 0.208))
            GoogleLogoPart(part: .blue).fill(Color(red: 0.259, green: 0.522, blue: 0.957))
            GoogleLogoPart(part: .yellow).fill(Color(red: 0.984, green: 0.737, blue: 0.020))
            GoogleLogoPart(part: .green).fill(Color(red: 0.204, green: 0.659, blue: 0.325))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct GoogleLogoPart: Shape {
    enum Part {
        case red, blue, yellow, green
    }

    let part: Part

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 48
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        switch part {
        case .red:
            path.move(to: p(24, 9.5))
            path.addCurve(to: p(33.21, 13.1), control1: p(27.54, 9.5), control2: p(30.71, 10.72))
            path.addLine(to: p(40.06, 6.25))
            path.addCurve(to: p(24, 0), control1: p(35.9, 2.38), control2: p(30.47, 0))
            path.addCurve(to: p(2.56, 13.22), control1: p(14.62, 0), control2: p(6.51, 5.38))
            path.addLine(to: p(10.54, 19.41))
            path.addCurve(to: p(24, 9.5), control1: p(12.43, 13.72), control2: p(17.74, 9.5))
        case .blue:
            path.move(to: p(46.98, 24.55))
            path.addCurve(to: p(46.6, 20), control1: p(46.98, 22.98), control2: p(46.83, 21.46))
            path.addLine(to: p(24, 20))
            path.addLine(to: p(24, 29.02))
            path.addLine(to: p(36.94, 29.02))
            path.addCurve(to: p(32.16, 36.2), control1: p(36.36, 31.98), control2: p(34.68, 34.5))
            path.addLine(to: p(39.89, 42.2))
            path.addCurve(to: p(46.98, 24.55), control1: p(44.4, 38.02), control2: p(46.98, 31.84))
        case .yellow:
            path.move(to: p(10.53, 28.59))
            path.addCurve(to: p(9.77, 24), control1: p(10.05, 27.14), control2: p(9.77, 25.6))
            path.addCurve(to: p(10.53, 19.41), control1: p(9.77, 22.4), control2: p(10.04, 20.86))
            path.addLine(to: p(2.55, 13.22))
            path.addCurve(to: p(0, 24), control1: p(0.92, 16.46), control2: p(0, 20.12))
            path.addCurve(to: p(2.56, 34.78), control1: p(0, 27.88), control2: p(0.92, 31.54))
            path.addLine(to: p(10.53, 28.59))
        case .green:
            path.move(to: p(24, 48))
            path.addCurve(to: p(39.89, 42.19), control1: p(30.48, 48), control2: p(35.93, 45.87))
            path.addLine(to: p(32.16, 36.19))
            path.addCurve(to: p(24, 38.49), control1: p(30.01, 37.64), control2: p(27.24, 38.49))
            path.addCurve(to: p(10.53, 28.58), control1: p(17.74, 38.49), control2: p(12.43, 34.27))
            path.addLine(to: p(2.55, 34.77))
            path.addCurve(to: p(24, 48), control1: p(6.51, 42.62), control2: p(14.62, 48))
        }
        path.closeSubpath()
        return path
    }
}
