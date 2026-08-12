import SwiftData
import SwiftUI

struct TravelArchiveView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var photos: [PhotoAnalysisRecord]
    @Query private var sessions: [ActivitySession]
    @Query private var stays: [StayRecord]
    @Query private var places: [CustomPlace]
    @Query private var timelineNodes: [TravelTimelineNode]
    @Query(sort: \TravelArchiveRecord.startTime, order: .reverse) private var archives: [TravelArchiveRecord]
    @State private var editorTarget: TravelArchiveEditorTarget?

    private var suggestions: [TravelArchiveSuggestion] {
        TravelArchiveDetectionService.suggestions(photos: photos,
                                                  sessions: sessions,
                                                  stays: stays,
                                                  places: places,
                                                  timelineNodes: timelineNodes,
                                                  confirmed: archives)
    }

    var body: some View {
        List {
            Section {
                if suggestions.isEmpty {
                    Text("暂未发现明显旅行。建议会综合照片 GPS、轨迹、停留地点和与日常区域的距离，仅在本机计算。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suggestions) { suggestion in
                        Button {
                            editorTarget = TravelArchiveEditorTarget(suggestion: suggestion)
                        } label: {
                            TravelArchiveRow(title: suggestion.title,
                                             startTime: suggestion.startTime,
                                             endTime: suggestion.endTime,
                                             photoCount: suggestion.photoCount,
                                             placeCount: suggestion.placeCount,
                                             distance: suggestion.totalDistance,
                                             isSuggestion: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("旅行建议")
            } footer: {
                Text("建议不会自动写入旅行归档；点开并确认后才会保存。")
            }

            if !archives.isEmpty {
                Section("已确认归档") {
                    ForEach(archives) { record in
                        Button {
                            editorTarget = TravelArchiveEditorTarget(record: record)
                        } label: {
                            TravelArchiveRow(title: record.title,
                                             startTime: record.startTime,
                                             endTime: record.endTime,
                                             photoCount: record.photoCount,
                                             placeCount: record.placeCount,
                                             distance: record.totalDistance,
                                             isSuggestion: false)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteArchives)
                }
            }
        }
        .navigationTitle("旅行归档")
        .sheet(item: $editorTarget) { target in
            TravelArchiveEditorView(target: target)
        }
    }

    private func deleteArchives(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(archives[index]) }
        PersistenceService.save(modelContext, operation: "删除旅行归档")
    }
}

private struct TravelArchiveRow: View {
    let title: String
    let startTime: Date
    let endTime: Date
    let photoCount: Int
    let placeCount: Int
    let distance: Double
    let isSuggestion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if isSuggestion {
                    Text("待确认")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.1), in: Capsule())
                }
            }
            Text(dateRange)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("照片 \(photoCount) 张 · 地点 \(placeCount) 个 · \(Formatters.distance(distance))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var dateRange: String {
        "\(startTime.formatted(.dateTime.year().month().day())) – \(endTime.formatted(.dateTime.year().month().day()))"
    }
}

private struct TravelArchiveEditorTarget: Identifiable {
    let id = UUID()
    let sourceFingerprint: String
    let title: String
    let startTime: Date
    let endTime: Date
    let photoCount: Int
    let placeCount: Int
    let totalDistance: Double
    let mainPlaces: [String]
    let record: TravelArchiveRecord?

    init(suggestion: TravelArchiveSuggestion) {
        sourceFingerprint = suggestion.sourceFingerprint
        title = suggestion.title
        startTime = suggestion.startTime
        endTime = suggestion.endTime
        photoCount = suggestion.photoCount
        placeCount = suggestion.placeCount
        totalDistance = suggestion.totalDistance
        mainPlaces = suggestion.mainPlaces
        record = nil
    }

    init(record: TravelArchiveRecord) {
        sourceFingerprint = record.sourceFingerprint
        title = record.title
        startTime = record.startTime
        endTime = record.endTime
        photoCount = record.photoCount
        placeCount = record.placeCount
        totalDistance = record.totalDistance
        mainPlaces = record.mainPlaces
        self.record = record
    }
}

private struct TravelArchiveEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let target: TravelArchiveEditorTarget
    @State private var title: String
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var saveError: String?

    init(target: TravelArchiveEditorTarget) {
        self.target = target
        _title = State(initialValue: target.title)
        _startTime = State(initialValue: target.startTime)
        _endTime = State(initialValue: target.endTime)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("旅行信息") {
                    TextField("旅行名称", text: $title)
                    DatePicker("开始日期", selection: $startTime, displayedComponents: .date)
                    DatePicker("结束日期", selection: $endTime, in: startTime..., displayedComponents: .date)
                }
                Section("识别依据") {
                    LabeledContent("照片", value: "\(target.photoCount) 张")
                    LabeledContent("地点", value: "\(target.placeCount) 个")
                    LabeledContent("移动距离", value: Formatters.distance(target.totalDistance))
                    if !target.mainPlaces.isEmpty {
                        ForEach(target.mainPlaces, id: \.self) { Label($0, systemImage: "mappin") }
                    }
                }
            }
            .navigationTitle(target.record == nil ? "确认旅行建议" : "编辑旅行归档")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(target.record == nil ? "确认归档" : "保存") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endTime < startTime)
                }
            }
            .alert("旅行归档未保存", isPresented: saveErrorPresented) {
                Button("好", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "请稍后重试。")
            }
        }
    }

    private func save() {
        if let record = target.record {
            record.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            record.startTime = startTime
            record.endTime = endTime
            record.updatedAt = .now
        } else {
            modelContext.insert(TravelArchiveRecord(sourceFingerprint: target.sourceFingerprint,
                                                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    startTime: startTime,
                                                    endTime: endTime,
                                                    photoCount: target.photoCount,
                                                    placeCount: target.placeCount,
                                                    totalDistance: target.totalDistance,
                                                    mainPlaces: target.mainPlaces))
        }
        let saved = PersistenceService.save(modelContext, operation: "保存旅行归档") { saveError = $0 }
        if saved { dismiss() }
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }
}
