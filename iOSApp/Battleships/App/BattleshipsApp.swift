import SwiftUI

@main
struct BattleshipsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.model)
        }
        .onChange(of: scenePhase, initial: true) {
            switch scenePhase {
            case .active:
                appDelegate.model.appDidBecomeActive()
            case .background:
                appDelegate.model.appDidEnterBackground()
            default:
                break
            }
        }
    }
}
