import Foundation
import SwiftData

/// 生活轨迹 AI 助手：一个基于本地工具的 Agent。
///
/// 隐私设计：
/// - 所有工具都只从本机 SwiftData 读取 **文字/数值** 数据。
/// - 不读取照片库或 PhotoAnalysisRecord，连本机生成的照片标签也不提供。
/// - 模型端（agnes-ai）没有任何照片内容通道。
@MainActor
enum LifeAgentService {

    // MARK: - 工具注册

    private static let emptyParams: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]
    private static let daysParams: [String: Any] = [
        "type": "object",
        "properties": ["days": ["type": "integer", "description": "统计最近多少天，默认 7"]],
        "required": []
    ]
    private static let dateParams: [String: Any] = [
        "type": "object",
        "properties": ["date": ["type": "string", "description": "查询日期，格式 YYYY-MM-DD；省略则使用今天"]],
        "required": []
    ]

    static let tools: [AgnesTool] = [
        AgnesTool(name: "get_activity_summary",
                  description: "获取某一天的运动/轨迹活动概览：总距离、活动时长、各活动类型的距离分布。",
                  parameters: dateParams),
        AgnesTool(name: "get_stay_summary",
                  description: "获取最近 N 天的停留地点与累计停留时长分布（仅文字，不含照片）。",
                  parameters: daysParams),
        AgnesTool(name: "get_schedule",
                  description: "获取本学期已启用的课程安排（星期、起止时间、地点、周次）。",
                  parameters: emptyParams),
        AgnesTool(name: "get_study_stats",
                  description: "获取最近 N 天在学习地点（标记为“学习教学”类别的地点）的停留次数与时长。",
                  parameters: daysParams),
        AgnesTool(name: "get_travel_archives",
                  description: "获取已确认的旅行归档列表：标题、起止日期、距离、主要地点。",
                  parameters: emptyParams)
    ]

    // MARK: - 生成入口

    /// 根据类型生成一段洞察，并持久化到 LifeInsightRecord。
    static func generate(_ kind: InsightKind, note userNote: String? = nil, context: ModelContext) async throws -> LifeInsightRecord {
        guard AgnesSettings.isConfigured else { throw AgnesError.notConfigured }
        let client = AgnesClient.shared

        let today = Self.dateString(Date())
        var messages: [AgnesWireMessage] = [
            .init(role: "system", content: Self.systemPrompt(for: kind)),
            .init(role: "user", content: Self.userPrompt(for: kind, today: today, note: userNote))
        ]

        var finalText = ""

        loop: for _ in 0..<6 {
            let outcome = try await client.completeWithTools(messages: messages, tools: Self.tools)
            switch outcome {
            case .content(let text):
                finalText = text
                break loop
            case .toolCalls(let calls):
                var next = messages
                next.append(.init(role: "assistant", toolCalls: calls))
                for call in calls {
                    let resultText = Self.executeTool(name: call.function.name,
                                                      args: call.arguments(),
                                                      context: context)
                    next.append(.init(role: "tool", content: resultText, toolCallId: call.id))
                }
                messages = next
            }
        }

        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgnesError.invalidResponse
        }

        let record = LifeInsightRecord(kind: kind.rawValue,
                                       title: kind.title,
                                       content: finalText.trimmingCharacters(in: .whitespacesAndNewlines),
                                       source: "agnes")
        context.insert(record)
        _ = PersistenceService.save(context, operation: "保存 AI 洞察", failureRecovery: .rollback)
        return record
    }

    // MARK: - 工具分发

    private static func executeTool(name: String, args: [String: Any], context: ModelContext) -> String {
        switch name {
        case "get_activity_summary": return runActivitySummary(args: args, context: context)
        case "get_stay_summary": return runStaySummary(args: args, context: context)
        case "get_schedule": return runSchedule(args: args, context: context)
        case "get_study_stats": return runStudyStats(args: args, context: context)
        case "get_travel_archives": return runTravelArchives(args: args, context: context)
        default: return "未知工具：\(name)"
        }
    }

    // MARK: - 本地工具实现（仅返回文字）

    private static func runActivitySummary(args: [String: Any], context: ModelContext) -> String {
        let date = parseDate(args["date"]) ?? Date()
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let descriptor = FetchDescriptor<ActivitySession>(
            predicate: #Predicate { $0.startTime >= start && $0.startTime < end }
        )
        let sessions = (try? context.fetch(descriptor)) ?? []
        if sessions.isEmpty {
            return "\(dateLabel(date)) 没有记录到任何轨迹或活动。"
        }
        let total = sessions.reduce(0) { $0 + $1.distance }
        let duration = sessions.reduce(0) { $0 + $1.duration }
        var byType: [String: Double] = [:]
        for session in sessions {
            byType[session.activityType.displayName, default: 0] += session.distance
        }
        var lines = ["\(dateLabel(date)) 活动概览：",
                     "移动距离 \(Formatters.distance(total))，活动时长 \(Formatters.duration(duration))，共 \(sessions.count) 段。"]
        for (name, dist) in byType.sorted(by: { $0.value > $1.value }) {
            lines.append("- \(name)：\(Formatters.distance(dist))")
        }
        return lines.joined(separator: "\n")
    }

    private static func runStaySummary(args: [String: Any], context: ModelContext) -> String {
        let days = (args["days"] as? Int) ?? 7
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let descriptor = FetchDescriptor<StayRecord>(
            predicate: #Predicate { $0.arrivalTime >= since }
        )
        let stays = (try? context.fetch(descriptor)) ?? []
        let places = (try? context.fetch(FetchDescriptor<CustomPlace>())) ?? []
        let placeNames = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0.shortName) })

        if stays.isEmpty {
            return "最近 \(days) 天没有停留记录。"
        }
        var byPlace: [String: (count: Int, duration: TimeInterval)] = [:]
        for stay in stays {
            let name = stay.customPlaceID.flatMap { placeNames[$0] } ?? stay.detectedName ?? "未知地点"
            let current = byPlace[name] ?? (0, 0)
            byPlace[name] = (current.count + 1, current.duration + stay.duration)
        }
        var lines = ["最近 \(days) 天停留 \(stays.count) 次："]
        for (name, value) in byPlace.sorted(by: { $0.value.duration > $1.value.duration }).prefix(12) {
            lines.append("- \(name)：\(value.count) 次，累计 \(Formatters.duration(value.duration))")
        }
        return lines.joined(separator: "\n")
    }

    private static func runSchedule(args: [String: Any], context: ModelContext) -> String {
        let descriptor = FetchDescriptor<CourseEvent>(
            predicate: #Predicate { $0.isEnabled },
            sortBy: [SortDescriptor(\.weekday), SortDescriptor(\.startMinutes)]
        )
        let courses = (try? context.fetch(descriptor)) ?? []
        if courses.isEmpty {
            return "还没有导入课表。导入后可帮助分析学习/生活节奏（见“课表”页面）。"
        }
        let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        var lines = ["本学期已启用课程（按星期）："]
        for weekday in 1...7 {
            let dayCourses = courses.filter { $0.weekday == weekday }
            guard !dayCourses.isEmpty else { continue }
            lines.append(weekdayNames[weekday - 1] + "：")
            for course in dayCourses {
                let start = String(format: "%02d:%02d", course.startMinutes / 60, course.startMinutes % 60)
                let end = String(format: "%02d:%02d", course.endMinutes / 60, course.endMinutes % 60)
                let location = course.locationName.isEmpty ? "" : " @ \(course.locationName)"
                let week = (course.weekParity != 0 || !course.weekRangesText.isEmpty) ? "（\(course.weekSummary)）" : ""
                lines.append("- \(course.name) \(start)–\(end)\(location)\(week)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func runStudyStats(args: [String: Any], context: ModelContext) -> String {
        let days = (args["days"] as? Int) ?? 30
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let studyPlaces = (try? context.fetch(FetchDescriptor<CustomPlace>(
            predicate: #Predicate { $0.categoryRawValue == "study" }
        ))) ?? []
        if studyPlaces.isEmpty {
            return "还没有把任何地点标记为“学习教学”类别，无法统计学习停留（可在“地点”页标记）。"
        }
        let ids = Set(studyPlaces.map { $0.id })
        let stays = (try? context.fetch(FetchDescriptor<StayRecord>(
            predicate: #Predicate { $0.arrivalTime >= since }
        ))) ?? []
        let studyStays = stays.filter { $0.customPlaceID.map(ids.contains) ?? false }
        if studyStays.isEmpty {
            return "最近 \(days) 天没有在学习地点停留的记录。"
        }
        var byPlace: [String: (count: Int, duration: TimeInterval)] = [:]
        for stay in studyStays {
            let name = stay.customPlaceID.flatMap { id in studyPlaces.first { $0.id == id }?.shortName } ?? "未知地点"
            let current = byPlace[name] ?? (0, 0)
            byPlace[name] = (current.count + 1, current.duration + stay.duration)
        }
        let total = studyStays.reduce(0) { $0 + $1.duration }
        var lines = ["最近 \(days) 天学习停留 \(studyStays.count) 次，累计 \(Formatters.duration(total))："]
        for (name, value) in byPlace.sorted(by: { $0.value.duration > $1.value.duration }) {
            lines.append("- \(name)：\(value.count) 次，\(Formatters.duration(value.duration))")
        }
        return lines.joined(separator: "\n")
    }

    private static func runTravelArchives(args: [String: Any], context: ModelContext) -> String {
        let descriptor = FetchDescriptor<TravelArchiveRecord>(
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        let archives = (try? context.fetch(descriptor)) ?? []
        if archives.isEmpty {
            return "还没有已确认的旅行归档（旅行建议确认后会生成归档）。"
        }
        var lines = ["已确认的旅行归档（最多 10 条）："]
        for archive in archives.prefix(10) {
            let range = "\(dateLabel(archive.startTime)) 至 \(dateLabel(archive.endTime))"
            let places = archive.mainPlaces.joined(separator: "、")
            lines.append("- \(archive.title)（\(range)，\(Formatters.distance(archive.totalDistance))，主要地点：\(places)）")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Prompt

    private static func systemPrompt(for kind: InsightKind) -> String {
        let base = """
        你是 LifeTrack 的私人生活轨迹助手。你只能依据工具返回的文字数据分析用户的生活与学习轨迹，\
        你无权访问用户的照片及任何照片派生数据；不要索要、猜测或声称看过照片。\
        语气温暖、简洁、像一位懂用户习惯的朋友。使用中文，用 Markdown 分段，控制在 300 字以内。
        """
        switch kind {
        case .dailyReflection:
            return base + "\n任务：写一段“今日回顾”。结合今天的活动与停留，说明今天去了哪、动了多久，并给一句温柔的鼓励或一个小建议。"
        case .weeklyReview:
            return base + "\n任务：写一份“本周复盘”。结合本周活动、停留、学习停留与课程，说明节奏如何、学习与生活是否平衡、值得肯定的地方，并给出下周一个可执行的微习惯。"
        case .learningLifeBalance:
            return base + "\n任务：分析“学娱平衡”。结合课程表、学习地点停留时长与日常活动/停留，判断学习投入是否充分、课余恢复是否足够，并给出 1-2 条具体建议。"
        case .travelStory:
            return base + "\n任务：写一段“旅行手记”。仅根据已确认的旅行归档，回顾旅行时间、路程与主要地点。"
        case .custom:
            return base
        }
    }

    private static func userPrompt(for kind: InsightKind, today: String, note: String?) -> String {
        let prefix: String
        switch kind {
        case .dailyReflection:
            prefix = "今天是 \(today)。请先获取今天的活动与停留，再写今日回顾。"
        case .weeklyReview:
            prefix = "今天是 \(today)。请获取本周的活动、停留、学习停留与课程，再做复盘。"
        case .learningLifeBalance:
            prefix = "今天是 \(today)。请获取课程表、学习地点停留与近期活动/停留，分析学娱平衡。"
        case .travelStory:
            prefix = "请仅获取已确认的旅行归档，帮我整理旅行记忆。"
        case .custom:
            prefix = "请依据可用工具中的数据，给我一段生活/学习轨迹的洞察。"
        }
        if let note, !note.isEmpty {
            return prefix + "\n额外要求：\(note)"
        }
        return prefix
    }

    // MARK: - 日期辅助

    private static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        return formatter.date(from: string)
    }
}
