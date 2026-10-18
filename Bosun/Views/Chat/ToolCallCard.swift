import SwiftUI

struct ToolCallCard: View {
    let call: ToolCall
    let result: ToolResult?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: result == nil ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                    .foregroundStyle(result == nil ? .orange : .green)
                Text("\(call.function.name)()")
                    .font(.system(.callout, design: .monospaced))
                    .bold()
                Spacer()
                if result == nil {
                    ProgressView().controlSize(.small)
                }
            }
            
            Text(call.function.arguments)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
