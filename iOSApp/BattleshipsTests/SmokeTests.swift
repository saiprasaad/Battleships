import BattleshipCore
@testable import Battleships
import Testing

struct SmokeTests {
    @Test func sharedEngineIsLinked() {
        #expect(GameMode.classic.rules.boardSize == 10)
    }
}
