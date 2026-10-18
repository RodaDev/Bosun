//
//  ModelPickerViewModel.swift
//  Bosun
//
//  Created by Dmitry on 18.10.2026.
//

import Foundation
import Observation

@MainActor
@Observable
final class ModelPickerViewModel {
    var models: [ModelInfo] = []
    var isLoading = false
    var error: String?
    var toolsOnly = true

    private let client: OpenRouterClient

    init(client: OpenRouterClient) {
        self.client = client
    }

    var visible: [ModelInfo] {
        toolsOnly ? models.filter(\.supportsTools) : models
    }

    func load(force: Bool = false) async {
        if !force && !models.isEmpty { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            models = try await client.fetchModels()
                .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
