import CoreLocation
import Foundation
import SwiftData

/// 针对个人第二大脑（Obsidian、Notion、Logseq 等）的 Markdown 日记导出选项。
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

private struct MarkdownSessionSnapshot: Sendable {
    let activityName: String
    let activityEmoji: String
    let startTime: Date
    let endTime: Date
    let distance: Double
    let duration: TimeInterval
}

private struct MarkdownStaySnapshot: Sendable {
    let name: String
    let latitude: Double
    let longitude: Double
    let arrivalTime: Date
    let departureTime: Date
    let duration: TimeInterval
    let categoryName: String?
    let isStudy: Bool
}

private struct MarkdownPlaceSnapshot: Sendable {
    let name: String
    let latitude: Double
    let longitude: Double
    let radius: Double
}

private struct MarkdownCourseSnapshot: Sendable {
    let name: String
    let locationName: String
    let startTime: Date
    let endTime: Date
    let weekSummary: String
}

private struct MarkdownInsightSnapshot: Sendable {
    let title: String
    let content: String
}

private struct MarkdownPhotoSnapshot: Sendable {
    let creationDate: Date
    let latitude: Double
    let longitude: Double
}

private struct DailyMarkdownSnapshot: Sendable {
    let dayString: String
    let generatedAt: Date
    let sessions: [MarkdownSessionSnapshot]
    let stays: [MarkdownStaySnapshot]
    let places: [MarkdownPlaceSnapshot]
    let courses: [MarkdownCourseSnapshot]
    let insight: MarkdownInsightSnapshot?
    let photos: [MarkdownPhotoSnapshot]
}

@MainActor
enum MarkdownExportService {
    /// SwiftData 必须在 MainActor 读取；读取后会转换为值快照，并在后台生成 Markdown。
    static func generateDailyMarkdown(for date: Date = Date(),
                                      context: ModelContext,
                                      photoDescriptors: [PhotoLibraryAssetDescriptor] = [],
                                      options: MarkdownExportOptions = .standard,
                                      calendar: Calendar = .current) async -> String {
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return "# \(Formatters.dayString(date)) 生活日记\n\n暂无数据"
        }
        let now = Date()

        // 直接按区间相交查询，既保留跨午夜记录，也避免导出今天时扫描全部历史。
        let sessionCandidates = (try? context.fetch(FetchDescriptor<ActivitySession>(
            predicate: #Predicate {
                $0.startTime < endOfDay && ($0.endTime == nil || $0.endTime! > startOfDay)
            },
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        ))) ?? []
        let sessions = sessionCandidates.filter {
            resolvedEnd(of: $0, now: now, calendar: calendar) > startOfDay
        }

        let stayCandidates = (try? context.fetch(FetchDescriptor<StayRecord>(
            predicate: #Predicate {
                $0.arrivalTime < endOfDay && ($0.departureTime == nil || $0.departureTime! > startOfDay)
            },
            sortBy: [SortDescriptor(\.arrivalTime, order: .forward)]
        ))) ?? []
        let stays = stayCandidates.filter {
            resolvedEnd(of: $0, now: now, calendar: calendar) > startOfDay
        }

        let places = (try? context.fetch(FetchDescriptor<CustomPlace>())) ?? []
        let placesByID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })

        let weekday = calendar.component(.weekday, from: date)
        let normalizedWeekday = weekday == 1 ? 7 : weekday - 1
        let courses = ((try? context.fetch(FetchDescriptor<CourseEvent>())) ?? [])
            .filter { $0.isEnabled && $0.weekday == normalizedWeekday }
            .sorted { $0.startMinutes < $1.startMinutes }

        let insight = (try? context.fetch(FetchDescriptor<LifeInsightRecord>(
            predicate: #Predicate { $0.createdAt >= startOfDay && $0.createdAt < endOfDay },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )))?.first

        let descriptorsForDay = photoDescriptors.filter {
            calendar.isDate($0.creationDate, inSameDayAs: date)
        }
        let photoMoments = TodayPhotoTrackService.momentsForRecordedTracks(
            descriptors: descriptorsForDay,
            sessions: sessions
        )

        let sessionSnapshots = sessions.map { session in
            let resolvedEnd = resolvedEnd(of: session, now: now, calendar: calendar)
            let clampedStart = max(session.startTime, startOfDay)
            let clampedEnd = min(resolvedEnd, endOfDay)
            let dayDuration = max(0, clampedEnd.timeIntervalSince(clampedStart))
            let fullDuration = max(resolvedEnd.timeIntervalSince(session.startTime), session.duration, 1)
            let dayDistance = session.distance * min(dayDuration / fullDuration, 1)
            return MarkdownSessionSnapshot(
                activityName: session.activityType.displayName,
                activityEmoji: activityEmoji(for: session.activityType),
                startTime: clampedStart,
                endTime: clampedEnd,
                distance: dayDistance,
                duration: dayDuration
            )
        }

        let staySnapshots = stays.map { stay in
            let resolvedEnd = resolvedEnd(of: stay, now: now, calendar: calendar)
            let clampedStart = max(stay.arrivalTime, startOfDay)
            let clampedEnd = min(resolvedEnd, endOfDay)
            let name = stay.detectedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let place = stay.customPlaceID.flatMap { placesByID[$0] }
            let resolvedName = (name?.isEmpty == false ? name : nil) ?? place?.shortName ?? "未命名地点"
            let isStudyName = ["学习", "教学", "图书馆", "自习"].contains { resolvedName.contains($0) }
            return MarkdownStaySnapshot(
                name: resolvedName,
                latitude: stay.latitude,
                longitude: stay.longitude,
                arrivalTime: clampedStart,
                departureTime: clampedEnd,
                duration: max(0, clampedEnd.timeIntervalSince(clampedStart)),
                categoryName: place?.category.displayName,
                isStudy: place?.category == .study || isStudyName
            )
        }

        let courseSnapshots = courses.compactMap { course -> MarkdownCourseSnapshot? in
            guard let start = calendar.date(byAdding: .minute,
                                            value: max(course.startMinutes, 0),
                                            to: startOfDay),
                  let end = calendar.date(byAdding: .minute,
                                          value: max(course.endMinutes, course.startMinutes),
                                          to: startOfDay) else { return nil }
            return MarkdownCourseSnapshot(name: course.name,
                                          locationName: course.locationName,
                                          startTime: start,
                                          endTime: end,
                                          weekSummary: course.weekSummary)
        }

        let snapshot = DailyMarkdownSnapshot(
            dayString: Formatters.dayString(date),
            generatedAt: now,
            sessions: sessionSnapshots,
            stays: staySnapshots,
            places: places.map {
                MarkdownPlaceSnapshot(name: $0.shortName,
                                      latitude: $0.latitude,
                                      longitude: $0.longitude,
                                      radius: $0.radius)
            },
            courses: courseSnapshots,
            insight: insight.map { MarkdownInsightSnapshot(title: $0.title, content: $0.content) },
            photos: photoMoments.map {
                MarkdownPhotoSnapshot(creationDate: $0.creationDate,
                                      latitude: $0.coordinate.latitude,
                                      longitude: $0.coordinate.longitude)
            }
        )

        return await Task.detached(priority: .utility) {
            render(snapshot: snapshot, options: options)
        }.value
    }

    static func createTemporaryMarkdownFile(content: String, for date: Date) throws -> URL {
        let fileName = "LifeTrack_\(Formatters.dayString(date)).md"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private static func resolvedEnd(of session: ActivitySession,
                                    now: Date,
                                    calendar: Calendar) -> Date {
        if let endTime = session.endTime { return max(endTime, session.startTime) }
        if session.duration > 0 { return session.startTime.addingTimeInterval(session.duration) }
        return session.isActive && calendar.isDateInToday(session.startTime) ? now : session.startTime
    }

    private static func resolvedEnd(of stay: StayRecord,
                                    now: Date,
                                    calendar: Calendar) -> Date {
        if let departureTime = stay.departureTime { return max(departureTime, stay.arrivalTime) }
        if stay.duration > 0 { return stay.arrivalTime.addingTimeInterval(stay.duration) }
        return calendar.isDateInToday(stay.arrivalTime) ? now : stay.arrivalTime
    }

    private static func activityEmoji(for type: ActivityType) -> String {
        switch type {
        case .walking: "🚶"
        case .running: "🏃"
        case .cycling: "🚴"
        case .automotive: "🚗"
        case .transit: "🚇"
        case .stationary: "🛑"
        case .unknown: "📍"
        }
    }

    private nonisolated static func render(snapshot: DailyMarkdownSnapshot,
                                            options: MarkdownExportOptions) -> String {
        let totalDistance = snapshot.sessions.reduce(0.0) { $0 + $1.distance }
        let totalActiveDuration = snapshot.sessions.reduce(0.0) { $0 + $1.duration }
        let totalStayDuration = snapshot.stays.reduce(0.0) { $0 + $1.duration }
        let studyStays = snapshot.stays.filter(\.isStudy)
        let totalStudyDuration = studyStays.reduce(0.0) { $0 + $1.duration }
        let visitedPlaceNames = uniqueNames(snapshot.stays.map(\.name))

        var md = ""
        if options.includeYAMLFrontmatter {
            let distanceKilometers = String(format: "%.2f", totalDistance / 1_000)
            md += "---\n"
            md += "date: \(snapshot.dayString)\n"
            md += "tags: [daily-log, lifetrack, quantified-self]\n"
            md += "total_distance_km: \(distanceKilometers)\n"
            md += "active_duration_min: \(Int(totalActiveDuration / 60))\n"
            md += "study_duration_min: \(Int(totalStudyDuration / 60))\n"
            md += "stay_duration_min: \(Int(totalStayDuration / 60))\n"
            if !visitedPlaceNames.isEmpty {
                let yamlPlaces = visitedPlaceNames.map(yamlDoubleQuoted).joined(separator: ", ")
                md += "visited_places: [\(yamlPlaces)]\n"
            }
            md += "---\n\n"
        }

        md += "# 📅 \(snapshot.dayString) 生活与轨迹复盘\n\n"

        if options.includeAISummary,
           let insight = snapshot.insight,
           !insight.content.isEmpty {
            md += "## 🤖 AI 生活管家洞察\n\n"
            md += "> **\(markdownInline(insight.title))**\n>\n"
            md += insight.content.components(separatedBy: .newlines)
                .map { "> \($0)" }
                .joined(separator: "\n")
            md += "\n\n---\n\n"
        }

        if options.includeStatsTable {
            let placePreview = visitedPlaceNames.prefix(3).map(markdownTableCell).joined(separator: "、")
            let placeSuffix = visitedPlaceNames.count > 3 ? " 等" : ""
            md += "## 📊 今日量化简报\n\n"
            md += "| 维度 | 统计数值 | 备注 |\n"
            md += "| :--- | :--- | :--- |\n"
            md += "| **总移动距离** | `\(Formatters.distance(totalDistance))` | \(activitySummary(snapshot.sessions)) |\n"
            md += "| **有效运动时长** | `\(Formatters.duration(totalActiveDuration))` | 连续记录 \(snapshot.sessions.count) 段 |\n"
            md += "| **自习/教学时长** | `\(Formatters.duration(totalStudyDuration))` | 涉及 \(studyStays.count) 次学习停留 |\n"
            md += "| **到访地点数** | `\(visitedPlaceNames.count) 个地点` | \(placePreview)\(placeSuffix) |\n"
            md += "\n---\n\n"
        }

        if options.includeTimeline {
            md += "## ⏱️ 今日时间线\n\n"
            let items = timelineItems(snapshot: snapshot, includeCoordinates: options.includeCoordinates)
            if items.isEmpty {
                md += "*今日暂无课程、连续轨迹或停留记录。*\n\n"
            } else {
                md += items.map { "- \($0.text)" }.joined(separator: "\n") + "\n\n"
            }
            md += "---\n\n"
        }

        if options.includePlaces && !snapshot.stays.isEmpty {
            md += "## 📍 地点停留记录\n\n"
            for (index, stay) in snapshot.stays.enumerated() {
                var line = "\(index + 1). **\(markdownInline(stay.name))** (\(Formatters.timeString(stay.arrivalTime)) ~ \(Formatters.timeString(stay.departureTime)), 停留 \(Formatters.duration(stay.duration)))"
                if let categoryName = stay.categoryName {
                    line += " `\(markdownInline(categoryName))`"
                }
                if options.includeCoordinates {
                    let coordinateText = String(format: "%.4f, %.4f", stay.latitude, stay.longitude)
                    line += " *(坐标: \(coordinateText))*"
                }
                md += line + "\n"
            }
            md += "\n---\n\n"
        }

        if options.includePhotoMoments && !snapshot.photos.isEmpty {
            md += "## 📸 沿途照片时刻\n\n"
            for photo in snapshot.photos {
                let placeName = nearestPlaceName(latitude: photo.latitude,
                                                 longitude: photo.longitude,
                                                 places: snapshot.places)
                let resolvedPlaceName = markdownInline(placeName ?? "沿途拍摄")
                var line = "- `\(Formatters.timeString(photo.creationDate))` 📷 **\(resolvedPlaceName)**"
                if options.includeCoordinates {
                    let coordinateText = String(format: "%.4f, %.4f", photo.latitude, photo.longitude)
                    line += " *(坐标: \(coordinateText))*"
                }
                md += line + "\n"
            }
            md += "\n---\n\n"
        }

        md += "*Generated privately by LifeTrack on device at \(Formatters.timeString(snapshot.generatedAt))*\n"
        return md
    }

    private nonisolated static func timelineItems(snapshot: DailyMarkdownSnapshot,
                                                  includeCoordinates: Bool) -> [(time: Date, text: String)] {
        var items: [(time: Date, text: String)] = snapshot.sessions.map { session in
            let text = "**\(Formatters.timeString(session.startTime)) - \(Formatters.timeString(session.endTime))** \(session.activityEmoji) \(markdownInline(session.activityName)) `\(Formatters.distance(session.distance))` (耗时 \(Formatters.duration(session.duration)))"
            return (session.startTime, text)
        }

        items += snapshot.stays.map { stay in
            var text = "**\(Formatters.timeString(stay.arrivalTime)) - \(Formatters.timeString(stay.departureTime))** 📍 停留 **\(markdownInline(stay.name))** (\(Formatters.duration(stay.duration)))"
            if includeCoordinates {
                let coordinateText = String(format: "%.4f, %.4f", stay.latitude, stay.longitude)
                text += " *(\(coordinateText))*"
            }
            return (stay.arrivalTime, text)
        }

        items += snapshot.courses.map { course in
            let location = course.locationName.isEmpty ? "" : " · 📍 \(markdownInline(course.locationName))"
            let text = "**\(Formatters.timeString(course.startTime)) - \(Formatters.timeString(course.endTime))** 📚 \(markdownInline(course.name))\(location) `\(markdownInline(course.weekSummary))`"
            return (course.startTime, text)
        }

        return items.sorted { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            return lhs.text < rhs.text
        }
    }

    private nonisolated static func activitySummary(_ sessions: [MarkdownSessionSnapshot]) -> String {
        guard !sessions.isEmpty else { return "无活动" }
        var distances: [String: Double] = [:]
        for session in sessions {
            distances[session.activityName, default: 0] += session.distance
        }
        return distances.sorted { $0.value > $1.value }
            .prefix(2)
            .map { "\(markdownTableCell($0.key)) \(Formatters.distance($0.value))" }
            .joined(separator: ", ")
    }

    private nonisolated static func uniqueNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private nonisolated static func nearestPlaceName(latitude: Double,
                                                     longitude: Double,
                                                     places: [MarkdownPlaceSnapshot]) -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        return places.compactMap { place -> (String, CLLocationDistance)? in
            let distance = location.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
            guard distance <= max(place.radius, 50) else { return nil }
            return (place.name, distance)
        }
        .min { $0.1 < $1.1 }?.0
    }

    private nonisolated static func yamlDoubleQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private nonisolated static func markdownInline(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private nonisolated static func markdownTableCell(_ value: String) -> String {
        markdownInline(value)
    }
}
