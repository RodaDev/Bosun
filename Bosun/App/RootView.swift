import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationSplitView {
            ProjectTreeView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            ChatView(vm: env.chatVM)
        }
        .navigationTitle("Bosun")
    }
}
