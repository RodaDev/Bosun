//
//  ModelPickerSheet.swift
//  Bosun
//
//  Created by Dmitry on 18.10.2026.
//

import SwiftUI

struct ModelPickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var vm = env.modelPickerVM
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Модель").font(.title2.bold())
                Spacer()
                Button("Обновить") { Task { await vm.load(force: true) } }
                    .disabled(vm.isLoading)
            }

            Toggle("Только с tools", isOn: $vm.toolsOnly)
                .toggleStyle(.checkbox)

            if vm.isLoading && vm.models.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if let err = vm.error {
                Text(err).foregroundStyle(.red)
                Button("Повторить") { Task { await vm.load(force: true) } }
            } else {
                List(vm.visible) { model in
                    Button {
                        env.chatVM.selectedModelId = model.id
                        env.settings.defaultModelId = model.id
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName).font(.body)
                                Text(model.id).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if env.chatVM.selectedModelId == model.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 300)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task { await vm.load() }
    }
}
