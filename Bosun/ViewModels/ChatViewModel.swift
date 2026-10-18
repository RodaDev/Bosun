import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    var draft: String = ""
    var messages: [ChatMessage] = []
    var streamingText: String = ""
    var isRunning: Bool = false
    var error: String?
    var selectedModelId: String?
    var cacheStats: CacheStats?

    struct CacheStats: Equatable {
        var promptTokens: Int
        var completionTokens: Int
        var cachedTokens: Int
    }

    private let settings: SettingsStore
    private let keychain: KeychainStore
    private let client: OpenRouterClient
    private var runTask: Task<Void, Never>?

    init(settings: SettingsStore, keychain: KeychainStore, client: OpenRouterClient) {
        self.settings = settings
        self.keychain = keychain
        self.client = client
        self.selectedModelId = settings.defaultModelId
    }

    var canSend: Bool {
        !isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedModelId != nil
    }

    func send() {
        guard canSend, let model = selectedModelId else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        error = nil
        streamingText = ""
        messages.append(ChatMessage(role: .user, content: text))
        isRunning = true

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.client.streamCompletion(
                    model: model,
                    messages: self.messages
                )
                var accumulated = ""
                var usage: CacheStats?
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    if !chunk.textDelta.isEmpty {
                        accumulated += chunk.textDelta
                        await MainActor.run { self.streamingText = accumulated }
                    }
                    if let p = chunk.promptTokens, let c = chunk.completionTokens {
                        usage = CacheStats(
                            promptTokens: p,
                            completionTokens: c,
                            cachedTokens: chunk.cachedTokens ?? 0
                        )
                    }
                }
                await MainActor.run {
                    if !accumulated.isEmpty {
                        self.messages.append(ChatMessage(role: .assistant, content: accumulated))
                    }
                    self.streamingText = ""
                    self.cacheStats = usage
                    self.isRunning = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.streamingText = ""
                    self.isRunning = false
                }
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        if !streamingText.isEmpty {
            messages.append(ChatMessage(role: .assistant, content: streamingText + " …"))
            streamingText = ""
        }
    }
}
