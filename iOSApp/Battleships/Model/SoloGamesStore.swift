import BattleshipAPI
import BattleshipCore
import Foundation
import Observation

/// Wins and losses against the computer, per difficulty.
struct SoloRecord: Codable, Equatable, Sendable {
    var wins: [Difficulty: Int] = [:]
    var losses: [Difficulty: Int] = [:]

    var totalWins: Int { wins.values.reduce(0, +) }
    var totalLosses: Int { losses.values.reduce(0, +) }

    mutating func record(won: Bool, against difficulty: Difficulty) {
        if won {
            wins[difficulty, default: 0] += 1
        } else {
            losses[difficulty, default: 0] += 1
        }
    }
}

/// Games against the computer. They're played entirely on the device and saved as JSON in
/// Application Support, so they work offline and survive the app being closed mid-battle.
@MainActor
@Observable
final class SoloGamesStore {
    /// Finished games kept for the lobby history.
    static let finishedGamesKept = 20

    private struct Archive: Codable {
        var matches: [ComputerMatch]
        var record: SoloRecord
    }

    private(set) var matches: [ComputerMatch] = []
    private(set) var record = SoloRecord()

    @ObservationIgnored private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Battleships", isDirectory: true)
        fileURL = base.appendingPathComponent("solo-games.json")
        load()
    }

    func match(_ id: UUID) -> ComputerMatch? {
        matches.first { $0.id == id }
    }

    @discardableResult
    func start(mode: GameMode, difficulty: Difficulty, fleet: [ShipPlacement]) throws -> ComputerMatch {
        let match = try ComputerMatch(mode: mode, difficulty: difficulty, playerFleet: fleet)
        matches.insert(match, at: 0)
        save()
        return match
    }

    /// Stores a new state of a match; the first time it ends, the result goes on the record.
    func update(_ match: ComputerMatch) {
        guard let index = matches.firstIndex(where: { $0.id == match.id }) else { return }
        let wasOver = matches[index].isOver
        matches[index] = match
        if !wasOver, let didWin = match.perspective.didWin {
            record.record(won: didWin, against: match.difficulty)
        }
        trimHistory()
        save()
    }

    func delete(_ id: UUID) {
        matches.removeAll { $0.id == id }
        save()
    }

    private func trimHistory() {
        let finished = matches.filter(\.isOver).sorted { $0.updatedAt > $1.updatedAt }
        guard finished.count > Self.finishedGamesKept else { return }
        let dropped = Set(finished.dropFirst(Self.finishedGamesKept).map(\.id))
        matches.removeAll { dropped.contains($0.id) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archive = try? APICoding.makeDecoder().decode(Archive.self, from: data)
        else { return }
        matches = archive.matches
        record = archive.record
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try APICoding.makeEncoder().encode(Archive(matches: matches, record: record))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            assertionFailure("Could not save games against the computer: \(error)")
        }
    }
}
