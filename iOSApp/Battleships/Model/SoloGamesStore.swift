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

extension SoloRecord {
    /// Skips difficulties this version doesn't know (a newer version may have added some) instead
    /// of losing the whole record.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wins = Self.tally(in: container, forKey: .wins)
        losses = Self.tally(in: container, forKey: .losses)
    }

    /// `Difficulty` isn't a string key, so a tally is stored as `[key, count, key, count, …]`.
    private static func tally(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> [Difficulty: Int] {
        guard var entries = try? container.nestedUnkeyedContainer(forKey: key) else { return [:] }
        var tally: [Difficulty: Int] = [:]
        while !entries.isAtEnd {
            guard let name = try? entries.decode(String.self), let count = try? entries.decode(Int.self) else { break }
            if let difficulty = Difficulty(rawValue: name) {
                tally[difficulty] = count
            }
        }
        return tally
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

    /// Reads an archive game by game, so one that can't be read (say, saved by a newer version of
    /// the app with rules this one doesn't know) doesn't take the others with it.
    private struct TolerantArchive: Decodable {
        var matches: [ComputerMatch] = []
        var record = SoloRecord()
        var isComplete = true

        private enum CodingKeys: String, CodingKey {
            case matches
            case record
        }

        /// Decodes any value, to step over one that can't be read.
        private struct Skip: Decodable {
            init(from decoder: any Decoder) throws {}
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var entries = try container.nestedUnkeyedContainer(forKey: .matches)
            while !entries.isAtEnd {
                if let match = try? entries.decode(ComputerMatch.self) {
                    matches.append(match)
                } else {
                    _ = try entries.decode(Skip.self)
                    isComplete = false
                }
            }
            if let record = try? container.decode(SoloRecord.self, forKey: .record) {
                self.record = record
            } else {
                isComplete = false
            }
        }
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
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let archive = try APICoding.makeDecoder().decode(TolerantArchive.self, from: data)
            matches = archive.matches
            record = archive.record
            if !archive.isComplete {
                keepCopy(of: data)
            }
        } catch {
            keepCopy(of: data)
        }
    }

    /// Saving rewrites the file, so first set aside a copy of one that couldn't be fully read.
    /// Nothing is lost for good: a newer version of the app may be able to read it.
    private func keepCopy(of data: Data) {
        let name = "solo-games.unreadable-\(Int(Date().timeIntervalSince1970)).json"
        try? data.write(to: fileURL.deletingLastPathComponent().appendingPathComponent(name), options: [.atomic])
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
