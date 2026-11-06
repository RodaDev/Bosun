import SwiftUI
import SwiftData

struct SessionListView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var env
    
    @Query(sort: \ChatSession.lastModified, order: .reverse) private var sessions: [ChatSession]
    
    var body: some View {
        List(selection: Binding(
            get: { env.chatVM.activeSession?.id },
            set: { newId in
                if let id = newId, let session = sessions.first(where: { $0.id == id }) {
                    env.chatVM.loadSession(session)
                }
            }
        )) {
            Section("История чатов") {
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(session.lastModified, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(session.id)
                    .contextMenu {
                        Button("Удалить", role: .destructive) {
                            if env.chatVM.activeSession == session {
                                env.chatVM.activeSession = nil
                                env.chatVM.messages = []
                            }
                            context.delete(session)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let newSession = ChatSession()
                    context.insert(newSession)
                    try? context.save()
                    env.chatVM.loadSession(newSession)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("Новый чат")
            }
        }
    }
}
