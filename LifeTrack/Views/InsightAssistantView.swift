import SwiftUI
import SwiftData

/// “助手”标签页：基于本机数据，用 agnes-ai 生成生活/学习轨迹洞察。
struct InsightAssistantView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LifeInsightRecord.createdAt, order: .reverse) private var insights: [LifeInsightRecord]

    @State private var isGenerating = false
    @State private var generatingKind: InsightKind?
    @State private var statusMessage: String?
    @State private var configurationNeeded = false

    private let kinds: [InsightKind] = [.dailyReflection, .weeklyReview, .learningLifeBalance, .travelStory]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(kinds, id: \.self) { kind in
                        Button { generate(kind) } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                        .disabled(isGenerating)
                    }
                } header: {
                    Text("生成洞察")
                } footer: {
                    Text("AI 只能读取活动、停留、课表和旅行归档等文字/数值数据；照片及照片分析结果均不可读取。")
                        .font(.footnote)
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("历史洞察") {
                    if insights.isEmpty {
                        Text("还没有生成洞察。点上方按钮，让 AI 帮你回顾生活与学习轨迹。")
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
            .navigationTitle("助手")
            .overlay {
                if isGenerating {
                    ProgressView(generatingKind.map { "正在生成：\($0.title)…" } ?? "正在生成…")
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
                Spacer()
                Text(insight.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(insight.content)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
