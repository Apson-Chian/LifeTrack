import CoreLocation
import Foundation
import SwiftData

/// 导出 CSV 数据与一份纯文本分析摘要，方便用户用 Excel/Python 自行分析。
enum CSVExportService {
    static func exportAll(from context: ModelContext) throws -> [URL] {
        let sessions = (try? context.fetch(FetchDescriptor<ActivitySession>())) ?? []
        let stays = (try? context.fetch(FetchDescriptor<StayRecord>())) ?? []
        let summaries = (try? context.fetch(FetchDescriptor<DailySummary>())) ?? []
        let places = (try? context.fetch(FetchDescriptor<CustomPlace>())) ?? []

        var urls: [URL] = []
        urls.append(try writeCSV(header: "日期,开始时间,结束时间,类型,距离米,时长秒,平均速度公里每小时,来源,是否活跃",
                                 rows: sessions.map(sessionRow), name: "轨迹"))
        urls.append(try writeCSV(header: "日期,到达时间,离开时间,地点,时长秒,来源",
                                 rows: stays.map(stayRow), name: "停留"))
        urls.append(try writeCSV(header: "日期,总距离米,步行米,跑步米,骑行米,驾车米,活动时长秒,停留次数",
                                 rows: summaries.map(summaryRow), name: "每日汇总"))
        urls.append(try writeAnalysisReport(sessions: sessions, stays: stays, places: places))
        return urls
    }

    // MARK: - 行构造

    private static func sessionRow(_ session: ActivitySession) -> [String] {
        let averageSpeed = session.duration > 0 ? session.distance / session.duration * 3.6 : 0
        return [
            dayString(session.startTime),
            timeString(session.startTime),
            session.endTime.map(timeString) ?? "",
            session.activityType.displayName,
            String(format: "%.1f", session.distance),
            String(format: "%.0f", session.duration),
            String(format: "%.1f", averageSpeed),
            session.sourceRawValue,
            session.isActive ? "是" : "否"
        ]
    }

    private static func stayRow(_ stay: StayRecord) -> [String] {
        return [
            dayString(stay.arrivalTime),
            timeString(stay.arrivalTime),
            stay.departureTime.map(timeString) ?? "",
            stay.detectedName ?? "未命名停留",
            String(format: "%.0f", stay.duration),
            stay.sourceRawValue
        ]
    }

    private static func summaryRow(_ summary: DailySummary) -> [String] {
        return [
            dayString(summary.date),
            String(format: "%.1f", summary.totalDistance),
            String(format: "%.1f", summary.walkingDistance),
            String(format: "%.1f", summary.runningDistance),
            String(format: "%.1f", summary.cyclingDistance),
            String(format: "%.1f", summary.automotiveDistance),
            String(format: "%.0f", summary.activeDuration),
            String(summary.stayCount)
        ]
    }

    // MARK: - 分析摘要

    private static func writeAnalysisReport(sessions: [ActivitySession],
                                            stays: [StayRecord],
                                            places: [CustomPlace]) throws -> URL {
        var lines: [String] = []
        lines.append("LifeTrack 数据分析摘要")
        lines.append("生成时间: \(ISO8601DateFormatter().string(from: .now))")
        lines.append("")

        let totalDistance = sessions.reduce(0) { $0 + $1.distance }
        let totalDuration = sessions.reduce(0) { $0 + $1.duration }
        lines.append("总览")
        lines.append("- 轨迹条数: \(sessions.count)")
        lines.append("- 总距离: \(String(format: "%.2f 公里", totalDistance / 1_000))")
        lines.append("- 总时长: \(durationText(totalDuration))")
        lines.append("")

        lines.append("按活动类型")
        let byType = Dictionary(grouping: sessions, by: \.activityType)
        for type in [ActivityType.walking, .running, .cycling, .automotive, .transit] {
            let group = byType[type] ?? []
            guard !group.isEmpty else { continue }
            let distance = group.reduce(0) { $0 + $1.distance }
            let duration = group.reduce(0) { $0 + $1.duration }
            lines.append("- \(type.displayName): \(group.count) 次 · \(String(format: "%.2f 公里", distance / 1_000)) · \(durationText(duration))")
        }
        lines.append("")

        let studyPlaces = Set(places.filter { $0.category == .study }.map(\.id))
        let studyStays = stays.filter { $0.customPlaceID.map(studyPlaces.contains) ?? false }
        let studyDuration = studyStays.reduce(0) { $0 + $1.duration }
        if studyDuration > 0 {
            lines.append("学习统计")
            lines.append("- 学习停留次数: \(studyStays.count)")
            lines.append("- 累计学习时长: \(durationText(studyDuration))")
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeTrack-分析-\(fileDate(Date.now)).txt")
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: - CSV 写入

    private static func writeCSV(header: String, rows: [[String]], name: String) throws -> URL {
        var lines = [header]
        lines.append(contentsOf: rows.map { $0.map(csvEscape).joined(separator: ",") })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeTrack-\(name)-\(fileDate(Date.now)).csv")
        try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        return url
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - 格式化

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)小时\(minutes)分钟" }
        return "\(minutes)分钟"
    }

    private static func fileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
