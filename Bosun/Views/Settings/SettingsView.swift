import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var showResetAlert = false

    var body: some View {
        Form {
            Section("OpenRouter") {
                LabeledContent("API key", value: env.settingsVM.hasKey ? "сохранён" : "не задан")
                Button("Удалить ключ", role: .destructive) {
                    env.settingsVM.removeAPIKey()
                }
                .disabled(!env.settingsVM.hasKey)
            }
            
            Section("Данные приложения") {
                Button("Очистить историю чатов", role: .destructive) {
                    showResetAlert = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 450)
        .alert("Очистить все чаты?", isPresented: $showResetAlert) {
            Button("Отмена", role: .cancel) {}
            Button("Очистить", role: .destructive) {
                let descriptor = FetchDescriptor<ChatSession>()
                if let sessions = try? context.fetch(descriptor) {
                    for session in sessions {
                        context.delete(session)
                    }
                    try? context.save()
                    env.chatVM.activeSession = nil
                    env.chatVM.messages = []
                }
            }
        } message: {
            Text("Все сохраненные диалоги будут удалены безвозвратно.")
        }
    }
}
