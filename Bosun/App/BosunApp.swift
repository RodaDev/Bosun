import SwiftUI

@main
struct BosunApp: App {
    @State private var env = AppEnvironment()
    
    var body: some Scene {
        WindowGroup {
            Group {
                if env.settings.hasAPIKey {
                    RootView().environment(env)
                } else {
                    OnboardingView().environment(env)
                }
            }
            .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
        
        Settings {
            SettingsView().environment(env)
        }
    }
}
