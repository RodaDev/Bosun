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
            Section("История") {
                ForEach(sessions) { session in
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 16))
                            .foregroundStyle(env.chatVM.activeSession?.id == session.id ? Color.white : Color.accentColor)
                            .frame(width: 24, height: 24)
                            .background(env.chatVM.activeSession?.id == session.id ? Color.accentColor : Color.accentColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            
                            Text(session.formattedDate)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(session.id)
                    .contextMenu {
                        Button("Удалить", role: .destructive) {
                            if env.chatVM.activeSession?.id == session.id {
                                env.chatVM.activeSession = nil
                                env.chatVM.messages = []
                            }
                            context.delete(session)
                            try? context.save()
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createNewSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("Создать новый чат")
            }
        }
    }
    
    private func createNewSession() {
        let newSession = ChatSession()
        context.insert(newSession)
        do {
            try context.save()
            print("СЕССИЯ СОЗДАНА: \(newSession.id)")
            env.chatVM.loadSession(newSession)
        } catch {
            print("ОШИБКА СОЗДАНИЯ СЕССИИ: \(error)")
        }
    }
}
