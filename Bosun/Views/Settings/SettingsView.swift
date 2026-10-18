import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section("OpenRouter") {
                LabeledContent("API key", value: env.settingsVM.hasKey ? "сохранён" : "не задан")
                Button("Удалить ключ", role: .destructive) {
                    env.settingsVM.removeAPIKey()
                }
                .disabled(!env.settingsVM.hasKey)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }
}
