import BattleshipAPI
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
        case username, password
    }

    @Environment(AppModel.self) private var app
    @State private var mode: Mode = .signIn
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?
    var onSuccess: @MainActor () -> Void = {}

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    ZStack {
                        SonarPing()
                            .frame(width: 130, height: 130)
                        Image(systemName: "scope")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(Theme.reticle)
                            .glow(Theme.reticle, radius: 10)
                    }
                    .frame(height: 104)
                    Text(mode == .signIn ? "Welcome back, Captain" : "Join the fleet")
                        .font(.display(22, weight: .heavy))
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                    Text("An account lets you battle other players and earn a rating.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.clear)

            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
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
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                .listRowBackground(Theme.rowBackground)
            }

            Section {
                Button { submit() } label: {
                    HStack {
                        Spacer()
                        if isWorking {
                            ProgressView()
                        } else {
                            Text(mode.rawValue)
                                .bold()
                        }
                        Spacer()
                    }
                }
                .disabled(!canSubmit)
            } footer: {
                Text("Server: \(app.settings.serverURL.host() ?? app.settings.serverURL.absoluteString)")
            }
            .listRowBackground(Theme.rowBackground)
        }
        .scrollContentBackground(.hidden)
        .background { OceanBackdrop() }
        .onChange(of: mode) { errorMessage = nil }
        .onAppear { focus = .username }
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
                errorMessage = error.userMessage
                app.feedback.play(.invalid)
            }
        }
    }
}
