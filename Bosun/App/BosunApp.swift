import SwiftUI
import SwiftData

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
            .frame(minWidth: 1100, minHeight: 700)
            .modelContainer(for: [ChatSession.self, StoredMessage.self])
        }
        .windowStyle(.titleBar)
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings {
            SettingsView().environment(env)
        }
    }
}
