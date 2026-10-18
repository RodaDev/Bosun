import SwiftUI

struct ApprovalSheet: View {
    let requests: [ApprovalRequest]
    let onApprove: (_ allowSession: Bool) -> Void
    let onReject: () -> Void
    
    @State private var allowSession = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(requests.count == 1 ? "Подтверждение изменений" : "Подтверждение изменений (\(requests.count))")
                    .font(.headline)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(requests) { req in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Файл: \(req.path)")
                                .font(.subheadline.bold())
                            DiffView(oldContent: req.oldContent, newContent: req.newContent)
                                .background(Color.black.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
            
            Toggle("Больше не спрашивать для этих инструментов в текущей сессии", isOn: $allowSession)
                .font(.caption)
            
            HStack {
                Spacer()
                Button("Отклонить", role: .destructive) { onReject() }
                Button("Применить всё") { onApprove(allowSession) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 700)
    }
}
