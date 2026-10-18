import SwiftUI
import AppKit

struct ProjectTreeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isRefreshing = false

    var body: some View {
        VStack {
            if let root = env.projectRoot {
                List {
                    Section {
                        Text(root.lastPathComponent)
                            .font(.headline)
                    }
                    
                    Section("Действия") {
                        Button {
                            isRefreshing = true
                            Task {
                                if let map = env.projectMap {
                                    _ = await map.refreshTree()
                                }
                                if let idx = env.symbolIndex {
                                    try? await idx.rebuild()
                                }
                                isRefreshing = false
                            }
                        } label: {
                            HStack {
                                if isRefreshing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("Обновить карту проекта")
                            }
                        }
                        .disabled(isRefreshing)
                        
                        Button("Сменить проект") { selectFolder() }
                    }
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
