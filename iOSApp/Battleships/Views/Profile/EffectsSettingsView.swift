import BattleshipCore
import SwiftUI

/// Profile → Settings → Effects: the player's own control over how much the game moves, lights up
/// and rumbles, so nobody has to open iOS Accessibility settings to tone it down. The Effects level
/// is what `MotionPolicy` turns into a tier (Minimal is the still tier with every sequence
/// collapsed), shown in a patch of living water above the rows that plays one hit when the level
/// changes; Screen Shake and Flashes preview on their icon when flipped; Haptic Strength plays a hit
/// at the new strength; Ambient Sound starts or stops the sea at once.
struct EffectsSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.motionPolicy) private var policy
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The ripple the preview tile plays when the level changes.
    @State private var previewImpacts: [WaterImpact] = []
    @State private var shakeBounces = 0
    @State private var flashBounces = 0
    @State private var ambientBounces = 0

    var body: some View {
        List {
            if showsPreview {
                Section {
                    EffectsPreviewTile(impacts: previewImpacts)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                } footer: {
                    Text("A patch of the sea, drawn the way the battle draws it.")
                        .foregroundStyle(Theme.secondaryText)
                }
                .listRowBackground(Color.clear)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Effects", systemImage: "sparkles")
                        // The picker carries the same name for VoiceOver.
                        .accessibilityHidden(true)
                    Picker("Effects", selection: effectsLevel) {
                        ForEach(EffectsLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.vertical, 2)
                Toggle(isOn: screenShake) {
                    SettingsLabel(title: "Screen Shake", systemImage: "arrow.left.and.right", bounces: shakeBounces)
                }
                Toggle(isOn: flashes) {
                    SettingsLabel(title: "Flashes", systemImage: "bolt.fill", bounces: flashBounces)
                }
                .accessibilityLabel("Bright Flashes")
            } header: {
                SheetSectionHeader(title: "Motion")
            } footer: {
                Text(levelExplanation)
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.rowBackground)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Haptic Strength", systemImage: "slider.horizontal.3")
                        .accessibilityHidden(true)
                    Picker("Haptic Strength", selection: hapticLevel) {
                        ForEach(HapticLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.vertical, 2)
                .disabled(!app.settings.hapticsEnabled)
            } header: {
                SheetSectionHeader(title: "Haptics")
            } footer: {
                Text(hapticExplanation)
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.rowBackground)

            Section {
                Toggle(isOn: ambientSound) {
                    SettingsLabel(title: "Ambient Sound", systemImage: "water.waves", bounces: ambientBounces)
                }
            } header: {
                SheetSectionHeader(title: "Sound")
            } footer: {
                Text("The sea under the lobby and the battle. It plays while Sound Effects are on.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.rowBackground)
        }
        .scrollContentBackground(.hidden)
        .background { OceanBackdrop() }
        .navigationTitle("Effects")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { app.feedback.play(.navigate) }
        .onChange(of: app.settings.effectsLevel) { playPreviewHit() }
    }

    /// The living-water tile is left out in the still tier (nothing would move in it) and at
    /// accessibility sizes (the rows need the room).
    private var showsPreview: Bool {
        policy.tier != .still && !dynamicTypeSize.isAccessibilitySize
    }

    private var hapticExplanation: String {
        app.settings.hapticsEnabled
            ? "Each choice plays a hit, so you can feel it."
            : "Turn on Haptics in Settings to feel them."
    }

    private var levelExplanation: String {
        switch app.settings.effectsLevel {
        case .full: "Full: living water, shells in flight, bursts, smoke, flashes and shakes."
        case .reduced: "Reduced: the same motion, calmer and cheaper, with no flashes or shakes."
        case .minimal: "Minimal: decorative motion is taken out and sequences become short fades."
        }
    }

    // MARK: Controls

    private var effectsLevel: Binding<EffectsLevel> {
        Binding(
            get: { app.settings.effectsLevel },
            set: { level in
                guard level != app.settings.effectsLevel else { return }
                app.settings.effectsLevel = level
                app.feedback.play(.select)
            }
        )
    }

    private var screenShake: Binding<Bool> {
        Binding(
            get: { app.settings.screenShakeEnabled },
            set: { isOn in
                app.settings.screenShakeEnabled = isOn
                app.feedback.play(.select)
                if policy.tier == .full {
                    shakeBounces += 1
                }
            }
        )
    }

    private var flashes: Binding<Bool> {
        Binding(
            get: { app.settings.flashesEnabled },
            set: { isOn in
                app.settings.flashesEnabled = isOn
                app.feedback.play(.select)
                if policy.tier == .full {
                    flashBounces += 1
                }
            }
        )
    }

    private var hapticLevel: Binding<HapticLevel> {
        Binding(
            get: { HapticLevel.nearest(to: app.settings.hapticStrength) },
            set: { level in
                app.settings.hapticStrength = level.rawValue
                // The engine reads the strength as it plays, so this hit is at the new strength.
                app.feedback.play(.hit)
            }
        )
    }

    private var ambientSound: Binding<Bool> {
        Binding(
            get: { app.settings.ambientSoundEnabled },
            set: { isOn in
                app.settings.ambientSoundEnabled = isOn
                app.ambienceSettingDidChange()
                app.feedback.play(.select)
                if policy.tier == .full {
                    ambientBounces += 1
                }
            }
        )
    }

    /// One hit on the preview's middle cell, on the clock the water reads.
    private func playPreviewHit() {
        guard showsPreview else { return }
        let centre = EffectsPreviewTile.centre
        previewImpacts = [WaterImpact(x: centre.x, y: centre.y, start: Motion.seconds(Date()), kind: .hit)]
    }
}

/// The three strengths the Haptic Strength control offers, on `AppSettings.hapticStrength`'s 0…1.
enum HapticLevel: Double, CaseIterable, Identifiable {
    case light = 0.6
    case medium = 0.85
    case strong = 1.0

    var id: Double { rawValue }

    var displayName: String {
        switch self {
        case .light: "Light"
        case .medium: "Medium"
        case .strong: "Strong"
        }
    }

    /// The level nearest a stored strength (earlier builds saved any quarter step).
    static func nearest(to strength: Double) -> HapticLevel {
        allCases.min { abs($0.rawValue - strength) < abs($1.rawValue - strength) } ?? .strong
    }
}

/// A settings row's label whose icon bounces (`symbolEffect(.bounce)`) each time `bounces` changes:
/// the short preview a flipped toggle gives in the full tier.
struct SettingsLabel: View {
    let title: String
    let systemImage: String
    let bounces: Int

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .symbolEffect(.bounce, value: bounces)
        }
    }
}

/// A 3 × 3 patch of living water, with no labels, for seeing the Effects level in. `impacts` is
/// where a hit should ripple; `centre` is its middle cell, in the water's own coordinates.
private struct EffectsPreviewTile: View {
    static let side: CGFloat = 132
    static let rules = Rules(boardSize: 3, fleet: [])
    static var geometry: BoardGeometry {
        BoardGeometry(boardSize: rules.boardSize, side: side, showsLabels: false)
    }
    static var centre: CGPoint {
        geometry.center(of: Coordinate(row: 1, column: 1))
    }

    let impacts: [WaterImpact]

    var body: some View {
        BoardView(rules: Self.rules, showsLabels: false, seaState: 0.3, impacts: impacts) { _ in
            EmptyView()
        }
        .frame(width: Self.side, height: Self.side)
        .accessibilityHidden(true)
    }
}
