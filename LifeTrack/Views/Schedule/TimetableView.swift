import SwiftUI
import SwiftData
import Foundation
import UniformTypeIdentifiers

/// 周课表 + 课程编辑。
struct TimetableView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CourseEvent.weekday) private var courses: [CourseEvent]
    @State private var editingCourse: CourseEvent?
    @State private var showEditor = false
    @State private var persistenceError: String?
    @State private var showImportPicker = false
    @State private var showImportPreview = false
    @State private var importItems: [TimetableImportItem] = []
    @State private var importError: String?
    @State private var importMessage: String?

    private let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    var body: some View {
        List {
            ForEach(1...7, id: \.self) { weekday in
                let dayCourses = courses(for: weekday)
                Section(weekdays[weekday - 1]) {
                    if dayCourses.isEmpty {
                        Text("暂无课程")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(dayCourses) { course in
                            Button { editingCourse = course } label: {
                                CourseRow(course: course)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in delete(dayCourses, at: offsets) }
                    }
                }
            }
        }
        .navigationTitle("课表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editingCourse = nil
                        showEditor = true
                    } label: {
                        Label("手动添加课程", systemImage: "plus")
                    }
                    Button {
                        showImportPicker = true
                    } label: {
                        Label("从 CSV / 表格导入", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            CourseEditorView(course: editingCourse) { saved in
                showEditor = false
                if !saved { persistenceError = "保存课程失败，请重试。" }
            }
        }
        .sheet(isPresented: $showImportPreview) {
            TimetableImportPreviewView(items: importItems) { confirmed in
                importCourses(confirmed)
            }
        }
        .fileImporter(isPresented: $showImportPicker,
                      allowedContentTypes: [
                        .commaSeparatedText,
                        .plainText,
                        UTType(filenameExtension: "ics") ?? .text,
                        UTType(filenameExtension: "csv") ?? .commaSeparatedText,
                        UTType(filenameExtension: "xls") ?? .spreadsheet,
                        UTType(filenameExtension: "xlsx") ?? .spreadsheet
                      ]) { result in
            handleImport(result)
        }
        .alert("课程操作失败", isPresented: persistenceErrorPresented) {
            Button("好", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "请稍后重试。")
        }
        .alert("导入失败", isPresented: importErrorPresented) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "请稍后重试。")
        }
        .alert("导入完成", isPresented: importMessagePresented) {
            Button("好", role: .cancel) { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    private func courses(for weekday: Int) -> [CourseEvent] {
        courses.filter { $0.weekday == weekday && $0.isEnabled }
            .sorted { $0.startMinutes < $1.startMinutes }
    }

    private func delete(_ values: [CourseEvent], at offsets: IndexSet) {
        for index in offsets { modelContext.delete(values[index]) }
        let saved = PersistenceService.save(modelContext,
                                            operation: "删除课程",
                                            failureRecovery: .rollback) {
            persistenceError = $0
        }
        _ = saved
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            importItems = try TimetableImportService.importFile(at: url)
            showImportPreview = true
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importCourses(_ items: [TimetableImportItem]) {
        for item in items { modelContext.insert(item.makeCourse()) }
        let saved = PersistenceService.save(modelContext,
                                            operation: "导入课表",
                                            failureRecovery: .rollback) {
            persistenceError = $0
        }
        importMessage = saved ? "已导入 \(items.count) 门课程。" : nil
    }

    private var persistenceErrorPresented: Binding<Bool> {
        Binding(get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } })
    }

    private var importErrorPresented: Binding<Bool> {
        Binding(get: { importError != nil },
                set: { if !$0 { importError = nil } })
    }

    private var importMessagePresented: Binding<Bool> {
        Binding(get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } })
    }
}

private struct CourseRow: View {
    let course: CourseEvent

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: course.colorHex))
                .frame(width: 5, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(course.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(timeText(course.startMinutes))–\(timeText(course.endMinutes))" +
                     (course.locationName.isEmpty ? "" : " · \(course.locationName)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if course.weekParity != 0 || !course.weekRangesText.isEmpty {
                Text(course.weekSummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
        }
    }

    private func timeText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

/// 课程编辑（新增/修改）。
struct CourseEditorView: View {
    let course: CourseEvent?
    let onDone: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var weekday = 1
    @State private var startTime = Date()
    @State private var endTime = Date().addingTimeInterval(2 * 60 * 60)
    @State private var locationName = ""
    @State private var colorHex = "5E5CE6"
    @State private var weekParity = 0
    @State private var weekRangesText = ""
    @State private var isEnabled = true

    private let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private let colors = ["5E5CE6", "FF375F", "30B0C7", "FF9F0A", "34C759", "AF52DE"]

    init(course: CourseEvent?, onDone: @escaping (Bool) -> Void) {
        self.course = course
        self.onDone = onDone
        _name = State(initialValue: course?.name ?? "")
        _weekday = State(initialValue: course?.weekday ?? 1)
        _startTime = State(initialValue: Self.date(fromMinutes: course?.startMinutes ?? 8 * 60))
        _endTime = State(initialValue: Self.date(fromMinutes: course?.endMinutes ?? 10 * 60))
        _locationName = State(initialValue: course?.locationName ?? "")
        _colorHex = State(initialValue: course?.colorHex ?? "5E5CE6")
        _weekParity = State(initialValue: course?.weekParity ?? 0)
        _weekRangesText = State(initialValue: course?.weekRangesText ?? "")
        _isEnabled = State(initialValue: course?.isEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("课程") {
                    TextField("课程名称", text: $name)
                    TextField("上课地点（可选）", text: $locationName)
                    Picker("星期", selection: $weekday) {
                        ForEach(1...7, id: \.self) { Text(weekdays[$0 - 1]).tag($0) }
                    }
                    DatePicker("开始时间", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("结束时间", selection: $endTime, displayedComponents: .hourAndMinute)
                }
                Section("显示") {
                    Picker("颜色", selection: $colorHex) {
                        ForEach(colors, id: \.self) { hex in
                            HStack {
                                Circle().fill(Color(hex: hex)).frame(width: 16, height: 16)
                                Text(hex).font(.caption)
                            }
                            .tag(hex)
                        }
                    }
                    Picker("周次", selection: $weekParity) {
                        Text("每周").tag(0)
                        Text("单周").tag(1)
                        Text("双周").tag(2)
                    }
                    TextField("教学周范围（可选，如 1-12、1-3,5-11,13-18、19）", text: $weekRangesText)
                        .font(.footnote)
                    Toggle("启用该课程", isOn: $isEnabled)
                }
                if course != nil {
                    Section {
                        Button("删除课程", role: .destructive) {
                            deleteCourse()
                        }
                    }
                }
            }
            .navigationTitle(course == nil ? "添加课程" : "编辑课程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onDone(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        guard endTime > startTime else { return }

        let target = course ?? CourseEvent(weekday: weekday, startMinutes: 0, endMinutes: 0, name: trimmedName)
        target.name = trimmedName
        target.weekday = weekday
        target.startMinutes = Self.minutes(from: startTime)
        target.endMinutes = Self.minutes(from: endTime)
        target.locationName = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        target.colorHex = colorHex
        target.weekParity = weekParity
        target.weekRangesText = weekRangesText.trimmingCharacters(in: .whitespacesAndNewlines)
        target.isEnabled = isEnabled
        if course == nil { modelContext.insert(target) }

        let saved = PersistenceService.save(modelContext,
                                            operation: "保存课程",
                                            failureRecovery: .rollback)
        onDone(saved)
    }

    private func deleteCourse() {
        guard let course else { return }
        modelContext.delete(course)
        let saved = PersistenceService.save(modelContext,
                                            operation: "删除课程",
                                            failureRecovery: .rollback)
        onDone(saved)
    }

    private static func date(fromMinutes minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    private static func minutes(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var rgb: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgb)
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

/// 导入前确认：预览解析出的课程，可左滑删除误解析的行。
struct TimetableImportPreviewView: View {
    let onConfirm: ([TimetableImportItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var remaining: [TimetableImportItem]

    private let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    init(items: [TimetableImportItem], onConfirm: @escaping ([TimetableImportItem]) -> Void) {
        self.onConfirm = onConfirm
        _remaining = State(initialValue: items)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(remaining) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.subheadline.weight(.medium))
                            Text("\(weekdayNames[item.weekday - 1]) \(timeText(item.startMinutes))–\(timeText(item.endMinutes))" +
                                 (item.location.isEmpty ? "" : " · \(item.location)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.weekParity != 0 || !item.weekRangesText.isEmpty {
                            Text(item.weekSummary)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            remaining.removeAll { $0.id == item.id }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .overlay {
                if remaining.isEmpty {
                    ContentUnavailableView("没有课程",
                                           systemImage: "calendar.badge.exclamationmark",
                                           description: Text("导入列表为空，可返回重新选择文件。"))
                }
            }
            .navigationTitle("确认导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入 \(remaining.count) 门课") {
                        onConfirm(remaining)
                        dismiss()
                    }
                    .disabled(remaining.isEmpty)
                }
            }
        }
    }

    private func timeText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
