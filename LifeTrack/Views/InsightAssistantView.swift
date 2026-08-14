import SwiftData
import SwiftUI

/// 贯穿 LifeTrack 各功能的记录问答与洞察入口。
struct InsightAssistantView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LifeInsightRecord.createdAt, order: .reverse) private var insights: [LifeInsightRecord]

    let featureContext: AssistantFeatureContext
    let embedsNavigationStack: Bool

    @State private var question = ""
    @State private var conversation: [AssistantConversationTurn] = []
    @State private var isGenerating = false
    @State private var generatingKind: InsightKind?
    @State private var statusMessage: String?
    @State private var configurationNeeded = false
    @FocusState private var questionFocused: Bool

    private let kinds: [InsightKind] = [.dailyReflection, .weeklyReview, .learningLifeBalance, .travelStory]

    init(featureContext: AssistantFeatureContext = .general,
         embedsNavigationStack: Bool = true) {
        self.featureContext = featureContext
        self.embedsNavigationStack = embedsNavigationStack
    }

    @ViewBuilder
    var body: some View {
        if embedsNavigationStack {
            NavigationStack { content }
        } else {
            content
        }
    }

    private var content: some View {
        List {
            contextSection
            questionSection

            if !conversation.isEmpty {
                conversationSection
            }

            insightActions

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            historySection
        }
        .navigationTitle(featureContext == .general ? "助手" : featureContext.title)
        .navigationBarTitleDisplayMode(featureContext == .general ? .large : .inline)
        .overlay {
            if isGenerating {
                ProgressView(generatingKind.map { "正在生成：\($0.title)…" } ?? "正在查阅你的记录…")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("需要配置 AI", isPresented: $configurationNeeded) {
            Button("好", role: .cancel) { }
        } message: {
            Text("请先在“设置 → AI 助手”中开启并填写 Agnes API Key。")
        }
    }

    private var contextSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: featureContext.symbolName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(featureContext.title)
                        .font(.headline)
                    Text(contextDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var questionSection: some View {
        Section {
            TextField("例如：最近一个月我的运动量有什么变化？", text: $question, axis: .vertical)
                .lineLimit(2...5)
                .focused($questionFocused)
                .disabled(isGenerating)

            Button { askQuestion() } label: {
                Label("结合我的全部记录回答", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isGenerating || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(featureContext.suggestedQuestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            question = suggestion
                            questionFocused = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("问问你的记录")
        } footer: {
            Text("助手会按需查阅运动、轨迹、出行、停留、地点、课表、旅行及脱敏照片摘要；不会接收照片图像或照片敏感元数据。")
        }
    }

    private var conversationSection: some View {
        Section("本次问答") {
            ForEach(Array(conversation.enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: 8) {
                    Label(turn.question, systemImage: "person.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(turn.answer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var insightActions: some View {
        Section {
            ForEach(kinds, id: \.self) { kind in
                Button { generate(kind) } label: {
                    Label(kind.title, systemImage: kind.symbol)
                }
                .disabled(isGenerating)
            }
        } header: {
            Text("一键洞察")
        } footer: {
            Text("照片仅以脱敏后的类别与通用标签聚合参与，不包含人物、自拍、标识符、路径、坐标、时间或单张照片详情。")
        }
    }

    private var historySection: some View {
        Section("历史问答与洞察") {
            if insights.isEmpty {
                Text("还没有历史内容。你可以直接提问，也可以生成一键洞察。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(insights) { insight in
                    InsightRow(insight: insight)
                }
                .onDelete { delete($0) }
            }
        }
    }

    private var contextDescription: String {
        switch featureContext {
        case .general: "可以针对整个 App 的记录自由提问，也可以从下方生成固定主题洞察。"
        case .today: "从今日运动、轨迹和停留出发，也能与过去记录比较。"
        case .activity: "分析运动类型、距离、时长、趋势和自动出行。"
        case .places: "分析地点类别、到访频率和停留时长，不发送坐标。"
        case .schedule: "综合课程、学习停留、运动和恢复节奏。"
        case .photos: "只使用本机照片解析后的安全聚合内容，不读取图像。"
        case .travel: "综合旅行归档、出行、地点和脱敏照片主题。"
        }
    }

    private func askQuestion() {
        guard AgnesSettings.isConfigured else {
            configurationNeeded = true
            return
        }
        let submitted = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else { return }
        isGenerating = true
        generatingKind = nil
        statusMessage = nil
        questionFocused = false

        Task {
            do {
                let record = try await LifeAgentService.answer(question: submitted,
                                                               featureContext: featureContext,
                                                               history: conversation,
                                                               context: modelContext)
                conversation.append(.init(question: submitted, answer: record.content))
                question = ""
            } catch {
                statusMessage = "回答失败：\(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    private func generate(_ kind: InsightKind) {
        guard AgnesSettings.isConfigured else {
            configurationNeeded = true
            return
        }
        isGenerating = true
        generatingKind = kind
        statusMessage = nil
        Task {
            do {
                let record = try await LifeAgentService.generate(kind, context: modelContext)
                statusMessage = "已生成「\(record.title)」。"
            } catch {
                statusMessage = "生成失败：\(error.localizedDescription)"
            }
            isGenerating = false
            generatingKind = nil
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { modelContext.delete(insights[index]) }
        PersistenceService.save(modelContext, operation: "删除洞察", failureRecovery: .rollback)
    }
}

private struct InsightRow: View {
    let insight: LifeInsightRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: insight.kind.symbol)
                    .foregroundStyle(.tint)
                Text(insight.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Text(insight.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(insight.content)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}
