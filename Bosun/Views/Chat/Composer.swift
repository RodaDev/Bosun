import SwiftUI

struct Composer: View {
    @Bindable var vm: ChatViewModel
    var env: AppEnvironment
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    showPicker = true
                } label: {
                    Label(vm.selectedModelId ?? "Модель", systemImage: "cpu")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                Spacer()
                if vm.isRunning {
                    Button("Стоп", role: .destructive) { vm.cancel() }
                }
            }
            .font(.caption)

            HStack(alignment: .bottom) {
                TextField("Сообщение агенту…", text: $vm.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .onSubmit { vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap) }
                
                if vm.isRunning && vm.streamingText.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                }
                
                Button {
                    vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canSend)
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .sheet(isPresented: $showPicker) { ModelPickerSheet() }
    }
}
