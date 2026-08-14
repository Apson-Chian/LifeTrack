import SwiftData
import SwiftUI

/// 贯穿 LifeTrack 的生活管家：连续对话由 RootView 级任务中心管理，离开页面也不会中断。
struct InsightAssistantView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var assistantCenter: AssistantTaskCenter
    @Query(sort: \LifeInsightRecord.createdAt, order: .reverse) private var insights: [LifeInsightRecord]

    let featureContext: AssistantFeatureContext
    let embedsNavigationStack: Bool

    @State private var question = ""
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
        if embedsNavigationStack { NavigationStack { content } } else { content }
    }

    private var content: some View {
        List {
            stewardSection

            if !assistantCenter.conversation.isEmpty || assistantCenter.activeQuestion != nil {
                conversationSection
            }

            composerSection
            insightActions

            if let message = assistantCenter.statusMessage, !assistantCenter.isGenerating {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            historySection
        }
        .navigationTitle(featureContext == .general ? "生活管家" : featureContext.title)
        .navigationBarTitleDisplayMode(featureContext == .general ? .large : .inline)
        .toolbar {
            if !assistantCenter.conversation.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新对话") { assistantCenter.clearConversation() }
                        .disabled(assistantCenter.isGenerating)
                }
            }
        }
        .alert("需要配置 AI", isPresented: $configurationNeeded) {
            Button("好", role: .cancel) { }
        } message: {
            Text("请先在“设置 → AI 管家”中启用并配置 Agnes 或 DeepSeek。")
        }
    }

    private var stewardSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: featureContext.symbolName)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(featureContext.title).font(.headline)
                        Spacer()
                        Text(AISettings.selectedProvider.displayName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.indigo.opacity(0.12), in: Capsule())
                    }
                    Text(contextDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            Label("了解记录，不窥探照片", systemImage: "checkmark.shield.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.green)
        }
    }

    private var conversationSection: some View {
        Section("对话") {
            ForEach(Array(assistantCenter.conversation.enumerated()), id: \.offset) { _, turn in
                ChatBubble(text: turn.question, isUser: true)
                ChatBubble(text: turn.answer, isUser: false)
            }
            if let activeQuestion = assistantCenter.activeQuestion {
                ChatBubble(text: activeQuestion, isUser: true)
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在结合你的记录思考…")
                            .font(.subheadline.weight(.medium))
                        Text("你可以离开此页继续使用其他功能")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("停止", role: .destructive) { assistantCenter.cancel() }
                        .font(.caption)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var composerSection: some View {
        Section {
            TextField("问问你的运动、学习、地点或旅行…", text: $question, axis: .vertical)
                .lineLimit(2...5)
                .focused($questionFocused)
                .disabled(assistantCenter.isGenerating)

            Button { askQuestion() } label: {
                Label("发送", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(assistantCenter.isGenerating || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
            Text("继续问")
        } footer: {
            Text("管家按需查阅整个 App 的文字与数值记录；照片只提供本机脱敏后的主题聚合。")
        }
    }

    private var insightActions: some View {
        Section {
            ForEach(kinds, id: \.self) { kind in
                Button { generate(kind) } label: {
                    HStack {
                        Label(kind.title, systemImage: kind.symbol)
                        Spacer()
                        if assistantCenter.generatingKind == kind { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(assistantCenter.isGenerating)
            }
        } header: {
            Text("让管家主动整理")
        } footer: {
            Text("旅行整理先用家、学校和高频停留排除日常活动，再把旅行区间内的脱敏照片主题用于回忆。")
        }
    }

    private var historySection: some View {
        Section("过往回答与洞察") {
            if insights.isEmpty {
                Text("还没有历史内容。直接提问，或让管家主动整理一份回顾。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(insights) { InsightRow(insight: $0) }
                    .onDelete(perform: delete)
            }
        }
    }

    private var contextDescription: String {
        switch featureContext {
        case .general: "从运动、轨迹、地点、课表、旅行等记录理解你的生活，并陪你持续对话。"
        case .today: "先看今天发生了什么，也会与过去的生活节奏比较。"
        case .activity: "理解运动类型、距离、时长和变化趋势，给出可执行建议。"
        case .places: "理解常去地点和停留规律；地点坐标不会发送给模型。"
        case .schedule: "综合课程、学习停留、运动与恢复节奏。"
        case .photos: "只理解本机照片解析后的安全主题，不读取任何图像。"
        case .travel: "先排除家、学校与日常活动圈，再整理真正的旅行。"
        }
    }

    private func askQuestion() {
        guard AISettings.isConfigured else { configurationNeeded = true; return }
        let submitted = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if assistantCenter.ask(question: submitted,
                               featureContext: featureContext,
                               modelContext: modelContext) {
            question = ""
            questionFocused = false
        }
    }

    private func generate(_ kind: InsightKind) {
        guard AISettings.isConfigured else { configurationNeeded = true; return }
        _ = assistantCenter.generate(kind, modelContext: modelContext)
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { modelContext.delete(insights[index]) }
        PersistenceService.save(modelContext, operation: "删除洞察", failureRecovery: .rollback)
    }
}

private struct ChatBubble: View {
    let text: String
    let isUser: Bool

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 42) }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(isUser ? Color.accentColor : Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            if !isUser { Spacer(minLength: 42) }
        }
        .listRowSeparator(.hidden)
    }
}

private struct InsightRow: View {
    let insight: LifeInsightRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: insight.kind.symbol).foregroundStyle(.tint)
                Text(insight.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer()
                Text(insight.source == AIProvider.deepSeek.rawValue ? "DeepSeek" : "Agnes")
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
