import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var showResetAlert = false

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section("OpenRouter") {
                LabeledContent("API key", value: env.settingsVM.hasKey ? "сохранён" : "не задан")
                Button("Удалить ключ", role: .destructive) {
                    env.settingsVM.removeAPIKey()
                }
                .disabled(!env.settingsVM.hasKey)
            }
            
            Section("Агент") {
                Stepper("Лимит итераций: \(settings.maxIterations)", value: $settings.maxIterations, in: 10...200, step: 10)
                    .help("Максимальное количество шагов, которое агент может сделать за один запрос.")
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
