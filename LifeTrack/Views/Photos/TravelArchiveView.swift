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
    @State private var deleteError: String?

    private var suggestions: [TravelArchiveSuggestion] {
        TravelArchiveDetectionService.suggestions(photos: photos,
                                                  sessions: sessions,
                                                  stays: stays,
                                                  places: places,
                                                  timelineNodes: timelineNodes,
                                                  confirmed: archives)
    }

    private var routineSummary: String {
        TravelArchiveDetectionService.routineSummary(places: places, stays: stays)
    }

    var body: some View {
        List {
            Section {
                AssistantFeatureCard(context: .travel,
                                     title: "让 AI 管家整理旅行",
                                     subtitle: "结合日常活动圈、异地轨迹和脱敏照片主题，回答和整理你的旅行")

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "house.and.flag.fill")
                        .foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已识别日常活动圈")
                            .font(.subheadline.weight(.semibold))
                        Text(routineSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("先根据家、学校和长期高频停留排除日常活动。照片不会产生旅行建议，只在本机核对是否属于已经识别出的旅行时段。")
            }

            Section {
                if suggestions.isEmpty {
                    Text("暂未发现明显旅行。只有明显离开日常活动圈、并有异地轨迹或停留依据时才会建议归档。")
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
                                             isSuggestion: true,
                                             detail: suggestion.reason)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("旅行建议")
            } footer: {
                Text("AI 可以帮助整理与总结，但建议不会自动写入归档；你确认后才会保存。")
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
                                             isSuggestion: false,
                                             detail: nil)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteArchives)
                }
            }
        }
        .navigationTitle("旅行归档")
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AssistantToolbarLink(context: .travel)
            }
        }
        .sheet(item: $editorTarget) { target in
            TravelArchiveEditorView(target: target)
        }
        .alert("旅行归档未删除", isPresented: deleteErrorPresented) {
            Button("好", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "请稍后重试。")
        }
    }

    private func deleteArchives(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(archives[index]) }
        PersistenceService.save(modelContext,
                                operation: "删除旅行归档",
                                failureRecovery: .rollback) { deleteError = $0 }
    }

    private var deleteErrorPresented: Binding<Bool> {
        Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
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
    let detail: String?

    private var accent: Color { isSuggestion ? .orange : .accentColor }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 6)
                .fill(accent.gradient)
                .frame(width: 5, height: 46)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isSuggestion {
                        Text("待确认")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }

                Text(dateRange)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    stat(icon: "photo", value: "\(photoCount)")
                    stat(icon: "mappin.and.ellipse", value: "\(placeCount)")
                    stat(icon: "figure.hiking", value: Formatters.distance(distance))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(isSuggestion ? 0.35 : 0.18), lineWidth: 1)
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    private func stat(icon: String, value: String) -> some View {
        Label {
            Text(value)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(accent)
        }
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
    let reason: String?
    let routineSummary: String?
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
        reason = suggestion.reason
        routineSummary = suggestion.routineSummary
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
        reason = nil
        routineSummary = nil
        self.record = record
    }
}

private struct TravelArchiveEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ActivitySession.startTime, order: .forward) private var allSessions: [ActivitySession]
    @Query(sort: \CustomPlace.shortName) private var allPlaces: [CustomPlace]
    let target: TravelArchiveEditorTarget
    @State private var title: String
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var mainPlaces: [String]
    @State private var newPlaceName = ""
    @State private var saveError: String?

    init(target: TravelArchiveEditorTarget) {
        self.target = target
        _title = State(initialValue: target.title)
        _startTime = State(initialValue: target.startTime)
        _endTime = State(initialValue: target.endTime)
        _mainPlaces = State(initialValue: target.mainPlaces)
    }

    private var mapPoints: [TrackMapPoint] {
        allSessions.filter { session in
            let end = session.endTime ?? session.startTime.addingTimeInterval(session.duration)
            return end >= startTime && session.startTime <= endTime
        }
        .flatMap(\.trackPoints)
        .sorted { $0.timestamp < $1.timestamp }
        .map(TrackMapPoint.init)
        .downsampledForMap()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TrackMapView(points: mapPoints,
                                 places: allPlaces,
                                 currentLocation: nil,
                                 style: .vivid) { _ in }
                        .frame(height: 240)
                        .overlay(alignment: .bottomLeading) { TrackSpeedLegend().padding(10) }
                        .listRowInsets(EdgeInsets())
                } header: {
                    Text("旅行轨迹")
                }

                Section("旅行信息") {
                    TextField("旅行名称", text: $title)
                    DatePicker("开始日期", selection: $startTime, displayedComponents: .date)
                    DatePicker("结束日期", selection: $endTime, in: startTime..., displayedComponents: .date)
                }

                Section("地点") {
                    ForEach(mainPlaces, id: \.self) { place in
                        Label(place, systemImage: "mappin")
                    }
                    .onDelete(perform: deletePlace)
                    HStack {
                        TextField("添加地点", text: $newPlaceName)
                        Button("添加") { addPlace() }
                            .disabled(newPlaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("识别依据") {
                    LabeledContent("照片", value: "\(target.photoCount) 张")
                    LabeledContent("地点", value: "\(mainPlaces.count) 个")
                    LabeledContent("移动距离", value: Formatters.distance(target.totalDistance))
                    if let routineSummary = target.routineSummary {
                        LabeledContent("已排除", value: routineSummary)
                    }
                    if let reason = target.reason {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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

    private func addPlace() {
        let name = newPlaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !mainPlaces.contains(name) else { return }
        mainPlaces.append(name)
        newPlaceName = ""
    }

    private func deletePlace(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) { mainPlaces.remove(at: index) }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let record = target.record {
            record.title = trimmedTitle
            record.startTime = startTime
            record.endTime = endTime
            record.mainPlacesRawValue = mainPlaces.joined(separator: "\n")
            record.placeCount = mainPlaces.count
            record.updatedAt = .now
        } else {
            modelContext.insert(TravelArchiveRecord(sourceFingerprint: target.sourceFingerprint,
                                                    title: trimmedTitle,
                                                    startTime: startTime,
                                                    endTime: endTime,
                                                    photoCount: target.photoCount,
                                                    placeCount: mainPlaces.count,
                                                    totalDistance: target.totalDistance,
                                                    mainPlaces: mainPlaces))
        }
        let saved = PersistenceService.save(modelContext,
                                            operation: "保存旅行归档",
                                            failureRecovery: .rollback) { saveError = $0 }
        if saved { dismiss() }
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }
}
