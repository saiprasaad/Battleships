import BattleshipCore
import SwiftUI

@main
struct BattleshipsApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Battleships · \(GameMode.classic.displayName)")
        }
    }
}
