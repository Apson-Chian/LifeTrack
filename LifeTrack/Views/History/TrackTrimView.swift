import SwiftData
import SwiftUI

struct TrackTrimView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let session: ActivitySession

    @State private var startPointCount = 0
    @State private var endPointCount = 0
    @State private var removesAnomalies = false
    @State private var showsConfirmation = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    private var orderedPoints: [TrackPoint] {
        session.trackPoints.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private var maximumStartCount: Int {
        max(0, orderedPoints.count - endPointCount - 2)
    }

    private var maximumEndCount: Int {
        max(0, orderedPoints.count - startPointCount - 2)
    }

    private var selectedPointIDs: Set<UUID> {
        var ids = Set(orderedPoints.prefix(startPointCount).map(\.id))
        ids.formUnion(orderedPoints.suffix(endPointCount).map(\.id))
        if removesAnomalies {
            ids.formUnion(orderedPoints.filter(\.isAnomaly).map(\.id))
        }
        return ids
    }

    private var remainingPoints: [TrackPoint] {
        orderedPoints.filter { !selectedPointIDs.contains($0.id) }
    }

    var body: some View {
        Form {
            Section("修剪范围") {
                Stepper(value: $startPointCount, in: 0...maximumStartCount) {
                    LabeledContent("删除开头", value: "\(startPointCount) 个点")
                }
                Stepper(value: $endPointCount, in: 0...maximumEndCount) {
                    LabeledContent("删除结尾", value: "\(endPointCount) 个点")
                }
                Toggle("删除已识别的异常点", isOn: $removesAnomalies)
                    .disabled(anomalyCount == 0)
                if anomalyCount > 0 {
                    Text("当前有 \(anomalyCount) 个疑似漂移或低质量定位点。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("预览") {
                LabeledContent("将删除", value: "\(selectedPointIDs.count) 个点")
                LabeledContent("将保留", value: "\(remainingPoints.count) 个点")
                if let first = remainingPoints.first, let last = remainingPoints.last {
                    LabeledContent("新起点", value: first.timestamp.formatted(date: .omitted, time: .standard))
                    LabeledContent("新终点", value: last.timestamp.formatted(date: .omitted, time: .standard))
                }
            }

            Section {
                Button("应用修剪", role: .destructive) {
                    showsConfirmation = true
                }
                .disabled(selectedPointIDs.isEmpty || remainingPoints.count < 2 || session.isActive)
            } footer: {
                Text("应用后会重新计算距离、时长、活动类型、停留记录和 Journey。删除操作不能直接撤销，建议先导出备份。")
            }
        }
        .navigationTitle("修剪轨迹")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认删除 \(selectedPointIDs.count) 个轨迹点？", isPresented: $showsConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除并重算", role: .destructive, action: applyTrim)
        } message: {
            Text("这会永久修改该条轨迹；至少保留两个点。")
        }
        .alert("轨迹修剪", isPresented: messagePresented) {
            Button("完成") {
                resultMessage = nil
                dismiss()
            }
        } message: {
            Text(resultMessage ?? "")
        }
        .alert("无法修剪", isPresented: errorPresented) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "请稍后重试。")
        }
    }

    private var anomalyCount: Int {
        orderedPoints.filter(\.isAnomaly).count
    }

    private func applyTrim() {
        do {
            let result = try TrackEditingService.trim(session: session,
                                                      removing: selectedPointIDs,
                                                      in: modelContext)
            resultMessage = "已删除 \(result.removedPointCount) 个点，保留 \(result.remainingPointCount) 个点。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var messagePresented: Binding<Bool> {
        Binding(get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
    }
}
