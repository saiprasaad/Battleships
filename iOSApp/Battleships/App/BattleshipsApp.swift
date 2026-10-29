import SwiftUI
import UIKit

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
            // Motion follows the scene: everything holds still in the background, and the display's
            // refresh rate caps the effects once a window is up.
            let isActive = scenePhase == .active
            MotionPreferences.shared.isActive = isActive
            TiltSensor.shared.setPaused(!isActive)
            if isActive, let screen = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first?.screen {
                MotionPreferences.shared.noteScreen(maximumFramesPerSecond: screen.maximumFramesPerSecond)
            }
            switch scenePhase {
            case .active:
                appDelegate.model.appDidBecomeActive()
                appDelegate.checkAppleIDCredential()
            case .background:
                appDelegate.model.appDidEnterBackground()
            default:
                break
            }
        }
    }
}
