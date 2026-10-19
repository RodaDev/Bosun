import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationSplitView {
            SessionListView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            ProjectTreeView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if env.chatVM.activeSession != nil {
                ChatView(vm: env.chatVM)
            } else {
                VStack {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Выберите чат слева или создайте новый")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Bosun")
    }
}
