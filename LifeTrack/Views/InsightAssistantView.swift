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
    @State private var showMarkdownExport = false
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

            composerSection

            if !assistantCenter.conversation.isEmpty || assistantCenter.activeQuestion != nil {
                conversationSection
            }

            insightActions

            if let message = assistantCenter.statusMessage, !assistantCenter.isGenerating {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            historySection
        }
        .navigationTitle(featureContext == .general ? "生活管家" : featureContext.title)
        .navigationBarTitleDisplayMode(featureContext == .general ? .large : .inline)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showMarkdownExport) {
            DailyMarkdownExportSheet(date: Date(), photoDescriptors: [])
        }
        .toolbar {
            if !assistantCenter.conversation.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新对话") { assistantCenter.clearConversation() }
                        .disabled(assistantCenter.isGenerating)
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起键盘") { questionFocused = false }
            }
        }
        .alert("需要配置 AI", isPresented: $configurationNeeded) {
            Button("好", role: .cancel) { }
        } message: {
            Text("请先在“设置 → AI 管家”中启用并配置 Agnes、DeepSeek 或 GLM。")
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

            Label(AISettings.sharesPhotoLocation ? "可按授权理解照片地点，不读取原图" : "了解记录，不窥探照片地点与原图",
                  systemImage: "checkmark.shield.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.green)
        }
    }

    private var conversationSection: some View {
        Section("对话") {
            if let activeQuestion = assistantCenter.activeQuestion {
                VStack(alignment: .leading, spacing: 10) {
                    Text("正在回答")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
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
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16))
                .listRowSeparator(.hidden)
            }
            ForEach(Array(assistantCenter.conversation.enumerated()).reversed(), id: \.offset) { index, turn in
                ConversationTurnCard(index: index + 1, question: turn.question, answer: turn.answer)
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
            HStack {
                Text("新对话")
                Spacer()
                if questionFocused {
                    Button("收起键盘") { questionFocused = false }
                        .font(.caption)
                        .textCase(nil)
                }
            }
        } footer: {
            Text(AISettings.sharesPhotoLocation
                 ? "已允许管家使用照片时间、精确坐标和地点做附近检索；原图和人物信息不会发送。"
                 : "照片地点当前未授权给 AI；管家仍无法读取照片画面。可在“设置 → AI 管家”中单独开启。")
        }
    }

    private var insightActions: some View {
        Section {
            ForEach(kinds, id: \.self) { kind in
                NavigationLink {
                    InsightKindDetailView(kind: kind)
                } label: {
                    HStack {
                        Label(kind.title, systemImage: kind.symbol)
                        Spacer()
                        if assistantCenter.generatingKind == kind { ProgressView().controlSize(.small) }
                    }
                }
            }

            Button {
                showMarkdownExport = true
            } label: {
                HStack {
                    Label("导出今日 Markdown 日记 (第二大脑)", systemImage: "doc.plaintext")
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("让管家主动整理")
        } footer: {
            Text("旅行整理先排除家、学校等日常区域，再结合照片时间、已授权地点和轨迹恢复旅行；照片画面不会交给 AI。")
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
        case .places: AISettings.sharesPhotoLocation ? "理解常去地点、精确照片坐标和附近关系。" : "理解常去地点和停留规律；照片地点未授权给模型。"
        case .schedule: "综合课程、学习停留、运动与恢复节奏。"
        case .photos: AISettings.sharesPhotoLocation ? "理解照片时间、精确地点、轨迹关联和本机安全主题，但不读取任何图像。" : "理解照片时间、轨迹关联和本机安全主题；照片地点未授权。"
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

    private func delete(_ offsets: IndexSet) {
        for index in offsets { modelContext.delete(insights[index]) }
        PersistenceService.save(modelContext, operation: "删除洞察", failureRecovery: .rollback)
    }
}

private struct ConversationTurnCard: View {
    let index: Int
    let question: String
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第 \(index) 轮")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ChatBubble(text: question, isUser: true)
            Divider()
            ChatBubble(text: answer, isUser: false)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

private struct ChatBubble: View {
    let text: String
    let isUser: Bool

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 42) }
            Text(text.assistantDisplayText)
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
                Text(AIProvider(rawValue: insight.source)?.displayName ?? insight.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(insight.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(insight.content.assistantDisplayText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

extension String {
    /// 模型常返回 Markdown 强调符号；原始内容仍保存在数据库，只在界面层清理展示。
    var assistantDisplayText: String {
        split(separator: "\n", omittingEmptySubsequences: false).map { rawLine in
            var line = String(rawLine)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* ") || line.hasPrefix("- ") {
                line = "• " + line.dropFirst(2)
            }
            return line
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "*", with: "")
        }
        .joined(separator: "\n")
    }
}

private struct InsightKindDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var assistantCenter: AssistantTaskCenter
    @Query(sort: \LifeInsightRecord.createdAt, order: .reverse) private var allInsights: [LifeInsightRecord]

    let kind: InsightKind

    @State private var configurationNeeded = false

    private var history: [LifeInsightRecord] {
        allInsights.filter { $0.kind == kind }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(kind.title, systemImage: kind.symbol)
                        .font(.title3.weight(.semibold))
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Button(action: generate) {
                    HStack {
                        Label("生成新的\(kind.title)", systemImage: "sparkles")
                        Spacer()
                        if assistantCenter.generatingKind == kind { ProgressView().controlSize(.small) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(assistantCenter.isGenerating)
            } footer: {
                Text("开始后可以离开此页，管家会在后台继续整理。")
            }

            Section("历史生成记录") {
                if history.isEmpty {
                    Text("还没有生成记录。点击上方按钮创建第一份内容。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history) { InsightRow(insight: $0) }
                        .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("需要配置 AI", isPresented: $configurationNeeded) {
            Button("好", role: .cancel) { }
        } message: {
            Text("请先在“设置 → AI 管家”中启用并配置 Agnes、DeepSeek 或 GLM。")
        }
    }

    private var description: String {
        switch kind {
        case .dailyReflection: "整理今天的运动、停留和安全的照片主题，形成一份今日回顾。"
        case .weeklyReview: "综合一周的活动、学习与生活节奏，给出下周可执行建议。"
        case .learningLifeBalance: "结合课程、学习地点停留、运动和恢复情况分析学娱平衡。"
        case .travelStory: "先排除家、学校和日常活动，再根据旅行记录整理手记。"
        case .custom: "结合 LifeTrack 中可用的文字和数值记录生成内容。"
        }
    }

    private func generate() {
        guard AISettings.isConfigured else { configurationNeeded = true; return }
        _ = assistantCenter.generate(kind, modelContext: modelContext)
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { modelContext.delete(history[index]) }
        PersistenceService.save(modelContext, operation: "删除洞察", failureRecovery: .rollback)
    }
}
