import SwiftData
import SwiftUI

/// 由 RootView 持有，因此用户离开助手页面后网络请求仍继续，完成后回到助手即可查看。
@MainActor
final class AssistantTaskCenter: ObservableObject {
    @Published private(set) var conversation: [AssistantConversationTurn] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var activeQuestion: String?
    @Published private(set) var generatingKind: InsightKind?
    @Published var statusMessage: String?

    private var workTask: Task<Void, Never>?

    func ask(question: String,
             featureContext: AssistantFeatureContext,
             modelContext: ModelContext) -> Bool {
        let submitted = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AISettings.isConfigured, !submitted.isEmpty, !isGenerating else { return false }
        let history = conversation
        isGenerating = true
        activeQuestion = submitted
        generatingKind = nil
        statusMessage = nil

        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let record = try await LifeAgentService.answer(question: submitted,
                                                               featureContext: featureContext,
                                                               history: history,
                                                               context: modelContext)
                conversation.append(.init(question: submitted, answer: record.content))
                statusMessage = "回答已完成"
            } catch is CancellationError {
                statusMessage = "已停止生成"
            } catch {
                statusMessage = "回答失败：\(error.localizedDescription)"
            }
            isGenerating = false
            activeQuestion = nil
            workTask = nil
        }
        return true
    }

    func generate(_ kind: InsightKind, modelContext: ModelContext) -> Bool {
        guard AISettings.isConfigured, !isGenerating else { return false }
        isGenerating = true
        activeQuestion = nil
        generatingKind = kind
        statusMessage = nil

        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let record = try await LifeAgentService.generate(kind, context: modelContext)
                statusMessage = "已生成「\(record.title)」"
            } catch is CancellationError {
                statusMessage = "已停止生成"
            } catch {
                statusMessage = "生成失败：\(error.localizedDescription)"
            }
            isGenerating = false
            generatingKind = nil
            workTask = nil
        }
        return true
    }

    func cancel() { workTask?.cancel() }

    func clearConversation() {
        guard !isGenerating else { return }
        conversation.removeAll()
        statusMessage = nil
    }
}
