import SwiftUI

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var key = ""
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Добро пожаловать в Bosun").font(.largeTitle.bold())
            Text("Вставьте OpenRouter API key. Он сохранится в Keychain и больше не будет запрошен.")
                .foregroundStyle(.secondary)
            SecureField("sk-or-...", text: $key)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Сохранить") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(key.isEmpty || isSaving)
            }
        }
        .padding(40)
        .frame(width: 520)
    }

    private func save() async {
        isSaving = true; defer { isSaving = false }
        do {
            try env.keychain.saveAPIKey(key)
            env.settings.hasAPIKey = true
        } catch {
            self.error = "Не удалось сохранить ключ: \(error.localizedDescription)"
        }
    }
}
