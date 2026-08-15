import Foundation
import SwiftData
import CoreLocation

/// 针对个人第二大脑（Obsidian、Notion、Logseq 等）的 Markdown 日记导出服务。
///
/// 特性：
/// - 纯本地异步组装，避免阻塞主线程；
/// - 生成标准 YAML Frontmatter，天然兼容 Obsidian Dataview 插件；
/// - 结构化时间线、量化统计表、自习地点停留与照片沿途时刻；
/// - 自由配置属性开关。
struct MarkdownExportOptions: Sendable, Equatable {
    var includeYAMLFrontmatter: Bool
    var includeAISummary: Bool
    var includeTimeline: Bool
    var includeStatsTable: Bool
    var includePlaces: Bool
    var includePhotoMoments: Bool
    var includeCoordinates: Bool

    init(includeYAMLFrontmatter: Bool = true,
         includeAISummary: Bool = true,
         includeTimeline: Bool = true,
         includeStatsTable: Bool = true,
         includePlaces: Bool = true,
         includePhotoMoments: Bool = true,
         includeCoordinates: Bool = false) {
        self.includeYAMLFrontmatter = includeYAMLFrontmatter
        self.includeAISummary = includeAISummary
        self.includeTimeline = includeTimeline
        self.includeStatsTable = includeStatsTable
        self.includePlaces = includePlaces
        self.includePhotoMoments = includePhotoMoments
        self.includeCoordinates = includeCoordinates
    }

    static let standard = MarkdownExportOptions()
}

@MainActor
enum MarkdownExportService {

    /// 异步为指定日期生成标准 Markdown 日记字符串。
    static func generateDailyMarkdown(for date: Date = Date(),
                                      context: ModelContext,
                                      photoDescriptors: [PhotoLibraryAssetDescriptor] = [],
                                      options: MarkdownExportOptions = .standard,
                                      calendar: Calendar = .current) async -> String {
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return "# \(Formatters.dayString(date)) 生活日记\n\n暂无数据"
        }

        // 1. 获取并过滤当日数据 (插入 Task.yield 避免长时间持有主线程)
        let sessions = (try? context.fetch(FetchDescriptor<ActivitySession>(
            predicate: #Predicate { $0.startTime >= startOfDay && $0.startTime < endOfDay },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        ))) ?? []
        await Task.yield()

        let stays = (try? context.fetch(FetchDescriptor<StayRecord>(
            predicate: #Predicate { $0.arrivalTime >= startOfDay && $0.arrivalTime < endOfDay },
            sortBy: [SortDescriptor(\.arrivalTime, order: .forward)]
        ))) ?? []
        await Task.yield()

        let places = (try? context.fetch(FetchDescriptor<CustomPlace>())) ?? []
        let placesByID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })

        let courses = (try? context.fetch(FetchDescriptor<CourseEvent>())) ?? []
        let weekday = calendar.component(.weekday, from: date)
        let normalizedWeekday = weekday == 1 ? 7 : weekday - 1 // 1=周一...7=周日
        let todayCourses = courses.filter { $0.weekday == normalizedWeekday }
        await Task.yield()

        let insights = (try? context.fetch(FetchDescriptor<LifeInsightRecord>(
            predicate: #Predicate { $0.createdAt >= startOfDay && $0.createdAt < endOfDay },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))) ?? []
        await Task.yield()

        // 2. 统计量化指标
        let totalDistance = sessions.reduce(0.0) { $0 + $1.distance }
        let totalActiveDuration = sessions.reduce(0.0) { $0 + $1.duration }
        let totalStayDuration = stays.reduce(0.0) { $0 + $1.duration }
        let studyStays = stays.filter { stay in
            if let placeID = stay.customPlaceID, placesByID[placeID]?.category == .study {
                return true
            }
            let name = stay.detectedName ?? ""
            return name.contains("学习") || name.contains("教学") || name.contains("图书馆") || name.contains("自习")
        }
        let totalStudyDuration = studyStays.reduce(0.0) { $0 + $1.duration }

        var visitedPlaceNames: [String] = []
        for stay in stays {
            if let name = stay.detectedName, !name.isEmpty, !visitedPlaceNames.contains(name) {
                visitedPlaceNames.append(name)
            }
        }

        let photoMoments = TodayPhotoTrackService.moments(descriptors: photoDescriptors, sessions: sessions)
        await Task.yield()

        // 3. 构建 Markdown 内容
        var md = ""
        let dayStr = Formatters.dayString(date)

        // YAML Frontmatter (Obsidian Dataview / Frontmatter 兼容)
        if options.includeYAMLFrontmatter {
            md += "---\n"
            md += "date: \(dayStr)\n"
            md += "tags: [daily-log, lifetrack, quantified-self]\n"
            md += "total_distance_km: \(String(format: "%.2f", totalDistance / 1000))\n"
            md += "active_duration_min: \(Int(totalActiveDuration / 60))\n"
            md += "study_duration_min: \(Int(totalStudyDuration / 60))\n"
            md += "stay_duration_min: \(Int(totalStayDuration / 60))\n"
            if !visitedPlaceNames.isEmpty {
                let formattedPlaces = visitedPlaceNames.map { "\"\($0)\"" }.joined(separator: ", ")
                md += "visited_places: [\(formattedPlaces)]\n"
            }
            md += "---\n\n"
        }

        md += "# 📅 \(dayStr) 生活与轨迹复盘\n\n"

        // AI 生活管家洞察
        if options.includeAISummary {
            if let latestInsight = insights.first, !latestInsight.content.isEmpty {
                md += "## 🤖 AI 生活管家洞察\n\n"
                md += "> **\(latestInsight.title)**\n>\n"
                let formattedLines = latestInsight.content.components(separatedBy: .newlines)
                    .map { "> \($0)" }
                    .joined(separator: "\n")
                md += "\(formattedLines)\n\n---\n\n"
            }
        }

        // 量化统计表
        if options.includeStatsTable {
            md += "## 📊 今日量化简报\n\n"
            md += "| 维度 | 统计数值 | 备注 |\n"
            md += "| :--- | :--- | :--- |\n"
            md += "| **总移动距离** | `\(Formatters.distance(totalDistance))` | \(activitySummary(sessions: sessions)) |\n"
            md += "| **有效运动时长** | `\(Formatters.duration(totalActiveDuration))` | 连续记录 \(sessions.count) 段 |\n"
            md += "| **自习/教学时长** | `\(Formatters.duration(totalStudyDuration))` | 涉及 \(studyStays.count) 次学习停留 |\n"
            md += "| **到访地点数** | `\(visitedPlaceNames.count) 个地点` | \(visitedPlaceNames.prefix(3).joined(separator: "、"))\(visitedPlaceNames.count > 3 ? " 等" : "") |\n"
            md += "\n---\n\n"
        }

        // 时间线 (Timeline)
        if options.includeTimeline {
            md += "## ⏱️ 今日时间线\n\n"
            let timelineItems = buildChronologicalTimeline(sessions: sessions,
                                                           stays: stays,
                                                           courses: todayCourses,
                                                           includeCoordinates: options.includeCoordinates)
            if timelineItems.isEmpty {
                md += "*今日暂无连续轨迹或停留记录。*\n\n"
            } else {
                for item in timelineItems {
                    md += "- \(item)\n"
                }
                md += "\n"
            }
            md += "---\n\n"
        }

        // 到访地点详情
        if options.includePlaces && !stays.isEmpty {
            md += "## 📍 地点停留记录\n\n"
            for (index, stay) in stays.enumerated() {
                let name = stay.detectedName ?? "未命名地点"
                let durationStr = Formatters.duration(stay.duration)
                let timeRange = "\(Formatters.timeString(stay.arrivalTime)) ~ \(stay.departureTime.map(Formatters.timeString) ?? "当前")"
                var placeLine = "\(index + 1). **\(name)** (\(timeRange), 停留 \(durationStr))"
                if let placeID = stay.customPlaceID, let place = placesByID[placeID] {
                    placeLine += " `\(place.category.displayName)`"
                }
                if options.includeCoordinates {
                    placeLine += " *(坐标: \(String(format: "%.4f, %.4f", stay.latitude, stay.longitude)))*"
                }
                md += "\(placeLine)\n"
            }
            md += "\n---\n\n"
        }

        // 沿途照片时刻
        if options.includePhotoMoments && !photoMoments.isEmpty {
            md += "## 📸 沿途照片时刻\n\n"
            for moment in photoMoments {
                let timeStr = Formatters.timeString(moment.creationDate)
                var line = "- `\(timeStr)` 📷"
                if let placeName = nearestPlaceName(to: moment.coordinate, places: places) {
                    line += " **\(placeName)**"
                } else {
                    line += " **沿途拍摄**"
                }
                if options.includeCoordinates {
                    line += " *(坐标: \(String(format: "%.4f, %.4f", moment.coordinate.latitude, moment.coordinate.longitude)))*"
                }
                md += "\(line)\n"
            }
            md += "\n---\n\n"
        }

        md += "*Generated privately by LifeTrack on device at \(Formatters.timeString(Date()))*\n"
        return md
    }

    /// 将生成的 Markdown 写入临时文件供系统分享面板使用。
    static func createTemporaryMarkdownFile(content: String, for date: Date) throws -> URL {
        let fileName = "LifeTrack_\(Formatters.dayString(date)).md"
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let fileURL = temporaryDirectory.appendingPathComponent(fileName)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - 辅助计算

    private static func activitySummary(sessions: [ActivitySession]) -> String {
        guard !sessions.isEmpty else { return "无活动" }
        var typeDistances: [ActivityType: Double] = [:]
        for s in sessions {
            typeDistances[s.activityType, default: 0] += s.distance
        }
        let sorted = typeDistances.sorted { $0.value > $1.value }
        return sorted.prefix(2).map { "\($0.key.displayName) \(Formatters.distance($0.value))" }.joined(separator: ", ")
    }

    private static func nearestPlaceName(to coordinate: CLLocationCoordinate2D,
                                         places: [CustomPlace]) -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return places.compactMap { place -> (name: String, distance: CLLocationDistance)? in
            let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let distance = location.distance(from: placeLocation)
            guard distance <= max(place.radius, 50) else { return nil }
            return (place.shortName, distance)
        }
        .min { $0.distance < $1.distance }?
        .name
    }

    private static func buildChronologicalTimeline(sessions: [ActivitySession],
                                                   stays: [StayRecord],
                                                   courses: [CourseEvent],
                                                   includeCoordinates: Bool) -> [String] {
        struct EventItem {
            let time: Date
            let text: String
        }

        var events: [EventItem] = []

        // 1. 添加运动轨迹事件
        for session in sessions {
            let start = Formatters.timeString(session.startTime)
            let end = session.endTime.map(Formatters.timeString) ?? "进行中"
            let emoji = activityEmoji(for: session.activityType)
            let text = "**\(start) - \(end)** \(emoji) \(session.activityType.displayName) `\(Formatters.distance(session.distance))` (耗时 \(Formatters.duration(session.duration)))"
            events.append(EventItem(time: session.startTime, text: text))
        }

        // 2. 添加停留事件
        for stay in stays {
            let start = Formatters.timeString(stay.arrivalTime)
            let end = stay.departureTime.map(Formatters.timeString) ?? "当前"
            let name = stay.detectedName ?? "未知地点"
            let duration = Formatters.duration(stay.duration)
            var text = "**\(start) - \(end)** 📍 停留 **\(name)** (\(duration))"
            if includeCoordinates {
                text += " *(\(String(format: "%.4f, %.4f", stay.latitude, stay.longitude)))*"
            }
            events.append(EventItem(time: stay.arrivalTime, text: text))
        }

        // 按时间升序排序
        events.sort { $0.time < $1.time }
        return events.map(\.text)
    }

    private static func activityEmoji(for type: ActivityType) -> String {
        switch type {
        case .walking: return "🚶"
        case .running: return "🏃"
        case .cycling: return "🚴"
        case .automotive: return "🚗"
        case .transit: return "🚇"
        case .stationary: return "🛑"
        case .unknown: return "📍"
        }
    }
}
