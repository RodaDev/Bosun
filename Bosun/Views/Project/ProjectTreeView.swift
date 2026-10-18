import SwiftUI

struct ProjectTreeView: View {
    var body: some View {
        List {
            Text("Проект не выбран").foregroundStyle(.secondary)
        }
        .listStyle(.sidebar)
    }
}
