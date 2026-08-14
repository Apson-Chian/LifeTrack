import SwiftData
import SwiftUI

struct DataHealthView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var snapshot: DataHealthSnapshot?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if let snapshot {
                Section("状态") {
                    LabeledContent("数据库占用", value: ByteCountFormatter.string(
                        fromByteCount: snapshot.databaseSize,
                        countStyle: .file
                    ))
                    LabeledContent("活跃记录", value: "\(snapshot.activeSessionCount)")
                    if snapshot.hasAbnormalActiveSession {
                        Label(abnormalSessionMessage(snapshot), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Label("没有发现异常活跃记录", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    LabeledContent("最近备份", value: snapshot.lastBackupDate?.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ) ?? "尚未备份")
                }

                Section("记录数量") {
                    ForEach(snapshot.recordCounts) { item in
                        LabeledContent(item.name, value: item.count.formatted())
                    }
                }

                Section {
                    Text("检查时间：\(snapshot.generatedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if isLoading {
                HStack {
                    Spacer()
                    ProgressView("正在检查…")
                    Spacer()
                }
            }

            if let errorMessage {
                Section("检查失败") {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("数据健康")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新", action: refresh)
                    .disabled(isLoading)
            }
        }
        .task { refresh() }
    }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            snapshot = try DataHealthService.inspect(context: modelContext)
        } catch {
            snapshot = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func abnormalSessionMessage(_ snapshot: DataHealthSnapshot) -> String {
        if snapshot.activeSessionCount > 1 {
            return "发现 \(snapshot.activeSessionCount) 条同时处于活跃状态的记录"
        }
        if let start = snapshot.oldestActiveSessionStart {
            return "活跃记录从 \(start.formatted(date: .abbreviated, time: .shortened)) 起尚未结束"
        }
        return "发现异常活跃记录"
    }
}
