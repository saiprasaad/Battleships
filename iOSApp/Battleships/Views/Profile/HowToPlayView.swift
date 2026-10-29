import BattleshipCore
import SwiftUI

/// The rules, briefly.
struct HowToPlayView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                Rule(icon: "square.grid.3x3.fill", title: "Deploy your fleet") {
                    Text("Before the battle, arrange your ships on your own grid. Drag a ship to move it, tap it to turn it, or press Shuffle. Ships can touch but not overlap.")
                }
                .staggeredEntrance(index: 0, trigger: 0)
                Rule(icon: "scope", title: "Take turns firing") {
                    Text("Tap a square in enemy waters to aim, then tap it again or press Fire. You get one shot per turn, hit or miss.")
                }
                .staggeredEntrance(index: 1, trigger: 0)
                Rule(icon: "flame.fill", title: "Hit, miss, sunk") {
                    Text("A white splash is a miss. A flame is a hit. When every square of a ship has been hit, it sinks and its position is revealed.")
                }
                .staggeredEntrance(index: 2, trigger: 0)
                Rule(icon: "trophy.fill", title: "Win") {
                    Text("Sink the entire enemy fleet before they sink yours. Online wins raise your rating; beating a stronger captain earns more.")
                }
                .staggeredEntrance(index: 3, trigger: 0)
                Rule(icon: "hourglass", title: "Keep it moving") {
                    Text("Online, each move has a time limit (three days on the standard server). If your opponent lets it run out, you can claim the win.")
                }
                .staggeredEntrance(index: 4, trigger: 0)
            }
            .listRowBackground(Theme.rowBackground)

            Section {
                ForEach(Array(GameMode.allCases.enumerated()), id: \.element.id) { index, mode in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mode.displayName)
                            .font(.headline)
                        Text(mode.tagline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .staggeredEntrance(index: 5 + index, trigger: 0)
                }
            } header: {
                SheetSectionHeader(title: "Rules")
            }
            .listRowBackground(Theme.rowBackground)

            Section {
                ForEach(Array(Difficulty.allCases.enumerated()), id: \.element.id) { index, difficulty in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(difficulty.displayName)
                            .font(.headline)
                        Text(difficulty.tagline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .staggeredEntrance(index: 7 + index, trigger: 0)
                }
            } header: {
                SheetSectionHeader(title: "The Computer")
            }
            .listRowBackground(Theme.rowBackground)
        }
        .scrollContentBackground(.hidden)
        .background { OceanBackdrop() }
        .navigationTitle("How to Play")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { app.feedback.play(.navigate) }
    }
}

private struct Rule<Detail: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.reticle)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                detail()
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
