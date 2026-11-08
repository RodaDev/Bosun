import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

struct Composer: View {
    @Bindable var vm: ChatViewModel
    var env: AppEnvironment
    @Environment(\.modelContext) private var context
    @State private var showPicker = false
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            if !vm.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(vm.pendingAttachments) { att in
                            HStack(spacing: 4) {
                                if att.type == .image { Image(systemName: "photo").foregroundStyle(.blue) }
                                else { Image(systemName: "doc.text").foregroundStyle(.orange) }
                                Text(att.fileName).lineLimit(1).font(.caption)
                                Button { vm.pendingAttachments.removeAll { $0.id == att.id } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }.padding(.horizontal, 12)
                }
            }

            HStack(spacing: 8) {
                Button { selectFile() } label: { Image(systemName: "paperclip") }.buttonStyle(.borderless)
                Button { showPicker = true } label: { Label(vm.selectedModelId ?? "Модель", systemImage: "cpu").labelStyle(.titleAndIcon) }.buttonStyle(.borderless)
                Spacer()
                if vm.isRunning { Button("Стоп", role: .destructive) { vm.cancel() } }
            }.font(.caption)

            HStack(alignment: .bottom) {
                TextField("Сообщение агенту…", text: $vm.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .onSubmit { 
                        Task { vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap, projectRules: env.projectRules, projectMemory: env.projectMemory, context: context) } 
                    }
                
                if vm.isRunning && vm.streamingText.isEmpty { ProgressView().controlSize(.small).padding(.bottom, 4) }
                
                Button {
                    Task { vm.send(toolRuntime: env.toolRuntime, projectMap: env.projectMap, projectRules: env.projectRules, projectMemory: env.projectMemory, context: context) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canSend)
            }
            .padding(10)
            .background(isTargeted ? Color.accentColor.opacity(0.2) : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .padding(12)
        .sheet(isPresented: $showPicker) { ModelPickerSheet() }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { DispatchQueue.main.async { vm.addFile(url: url) } }
                }
            }
            return true
        }
    }
    
    private func selectFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { vm.addFile(url: url) } }
    }
}
