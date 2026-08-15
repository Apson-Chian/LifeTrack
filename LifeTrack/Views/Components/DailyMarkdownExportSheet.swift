import SwiftUI
import SwiftData
import UIKit

/// 第二大脑 Markdown 导出与分享卡片。
struct DailyMarkdownExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let date: Date
    let photoDescriptors: [PhotoLibraryAssetDescriptor]

    @State private var viewMode: ExportViewMode = .preview
    @State private var options = MarkdownExportOptions.standard
    @State private var generatedMarkdown: String = ""
    @State private var isLoading = true
    @State private var isCopied = false
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var showOptionsConfig = false

    enum ExportViewMode: String, CaseIterable, Identifiable {
        case preview = "排版预览"
        case rawMarkdown = "Markdown 源码"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部模式切换与配置
                headerControls

                Divider()

                // 内容展示区
                if isLoading {
                    loadingView
                } else {
                    mainContentView
                }

                Divider()

                // 底部操作栏（复制与系统分享）
                bottomActionBar
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("导出每日 Markdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showOptionsConfig.toggle()
                        }
                    } label: {
                        Label("导出设置", systemImage: showOptionsConfig ? "slider.horizontal.3.fill" : "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let shareURL {
                    ShareSheet(items: [shareURL])
                }
            }
            .task(id: options) {
                await refreshMarkdown()
            }
        }
    }

    // MARK: - 视图子模块

    private var headerControls: some View {
        VStack(spacing: 12) {
            Picker("视图模式", selection: $viewMode) {
                ForEach(ExportViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if showOptionsConfig {
                optionsConfigurationPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var optionsConfigurationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导出要素自定义")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Toggle("YAML 头部 (Dataview)", isOn: $options.includeYAMLFrontmatter)
                    Toggle("AI 复盘洞察", isOn: $options.includeAISummary)
                }
                GridRow {
                    Toggle("今日时间线", isOn: $options.includeTimeline)
                    Toggle("量化简报表", isOn: $options.includeStatsTable)
                }
                GridRow {
                    Toggle("地点停留详情", isOn: $options.includePlaces)
                    Toggle("沿途照片时刻", isOn: $options.includePhotoMoments)
                }
                GridRow {
                    Toggle("包含地理坐标", isOn: $options.includeCoordinates)
                }
            }
            .font(.footnote)
            .toggleStyle(SwitchToggleStyle(tint: .indigo))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.indigo.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("正在聚合今日生活事实与轨迹…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainContentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if viewMode == .rawMarkdown {
                    rawMarkdownView
                } else {
                    richPreviewView
                }
            }
            .padding(16)
        }
    }

    private var rawMarkdownView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Markdown 纯文本", systemImage: "doc.text")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(generatedMarkdown.count) 字符")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(generatedMarkdown)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
        }
    }

    private var richPreviewView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 兼容性徽章
            HStack(spacing: 8) {
                Label("Obsidian", systemImage: "sparkles")
                Label("Notion", systemImage: "square.text.square")
                Label("Logseq", systemImage: "doc.plaintext")
                Spacer()
                Text("标准 GFM 格式")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())

            // 渲染正文
            Text(LocalizedStringKey(generatedMarkdown))
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
                )
        }
    }

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            // 一键复制按钮
            Button {
                copyToClipboard()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                        .font(.body.weight(.semibold))
                    Text(isCopied ? "已复制到剪贴板" : "复制 Markdown")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(isCopied ? .green : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isCopied ? Color.green.opacity(0.15) : Color.indigo)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(isCopied ? Color.green.opacity(0.4) : Color.clear, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(isLoading || generatedMarkdown.isEmpty)

            // 分享 .md 文件按钮
            Button {
                prepareAndShareFile()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                    Text("分享 .md 文件")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(isLoading || generatedMarkdown.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - 逻辑与交互

    private func refreshMarkdown() async {
        isLoading = true
        let text = await MarkdownExportService.generateDailyMarkdown(
            for: date,
            context: modelContext,
            photoDescriptors: photoDescriptors,
            options: options
        )
        await MainActor.run {
            self.generatedMarkdown = text
            self.isLoading = false
        }
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = generatedMarkdown
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        withAnimation(.snappy(duration: 0.25)) {
            isCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                isCopied = false
            }
        }
    }

    private func prepareAndShareFile() {
        do {
            let url = try MarkdownExportService.createTemporaryMarkdownFile(content: generatedMarkdown, for: date)
            self.shareURL = url
            self.showShareSheet = true
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        } catch {
            // 兜底剪贴板
            UIPasteboard.general.string = generatedMarkdown
        }
    }
}
