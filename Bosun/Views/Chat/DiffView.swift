import SwiftUI

struct DiffView: View {
    let oldContent: String?
    let newContent: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let old = oldContent, !old.isEmpty {
                Text(old)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.8))
                    .cornerRadius(4)
            } else {
                Text("(Создание нового файла)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            
            Text(newContent)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.8))
                .cornerRadius(4)
        }
        .padding(8)
    }
}
