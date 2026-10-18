import SwiftUI
import AppKit

struct ProjectTreeView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack {
            if let root = env.projectRoot {
                List {
                    Text(root.lastPathComponent)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Button("Сменить проект") { selectFolder() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .listStyle(.sidebar)
            } else {
                Spacer()
                Text("Проект не выбран")
                    .foregroundStyle(.secondary)
                Button("Открыть проект") { selectFolder() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top)
                Spacer()
            }
        }
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            env.projectRoot = url
        }
    }
}
