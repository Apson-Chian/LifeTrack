import Foundation
import SwiftData

/// V2 中首次引入的课程模型快照。迁移时必须保留旧字段集合，不能指向 V3 的模型类型。
extension LifeTrackSchemaV2 {
    @Model
    final class CourseEvent {
        @Attribute(.unique) var id: UUID
        var weekday: Int
        var startMinutes: Int
        var endMinutes: Int
        var name: String
        var locationName: String
        var colorHex: String
        var weekParity: Int
        var isEnabled: Bool
        var createdAt: Date

        init(weekday: Int,
             startMinutes: Int,
             endMinutes: Int,
             name: String,
             locationName: String = "",
             colorHex: String = "5E5CE6",
             weekParity: Int = 0,
             isEnabled: Bool = true) {
            self.id = UUID()
            self.weekday = weekday
            self.startMinutes = startMinutes
            self.endMinutes = endMinutes
            self.name = name
            self.locationName = locationName
            self.colorHex = colorHex
            self.weekParity = weekParity
            self.isEnabled = isEnabled
            self.createdAt = .now
        }
    }
}

/// 一条课程安排。用于课表展示与“上课中”状态判断。
///
/// 周次模型：
/// - `weekRangesText` 是权威字段，例如 `"1-12"`、`"1-3,5-11,13-18"`、`"19"`，
///   表示本学期内“哪些教学周有这门课”。为空字符串表示每周都上。
/// - `weekParity` 是兼容旧数据的快速标记：0=每周，1=单周，2=双周。
///   当 `weekRangesText` 非空时以它为准。
/// - `weekStart` / `weekEnd` 标记本学期的起始周与结束周（用于课表界面的“第几周”高亮）。
extension LifeTrackSchemaV3 {
@Model
final class CourseEvent {
    @Attribute(.unique) var id: UUID
    /// 1=周一 … 7=周日
    var weekday: Int
    /// 当天开始时间（自 00:00 起的分钟数）
    var startMinutes: Int
    /// 当天结束时间（自 00:00 起的分钟数）
    var endMinutes: Int
    var name: String
    var locationName: String
    var colorHex: String
    /// 单双周（兼容旧数据）：0=每周，1=单周，2=双周
    var weekParity: Int
    /// 学期起始教学周（含），默认 1
    var weekStart: Int = 1
    /// 学期结束教学周（含），默认 18
    var weekEnd: Int = 18
    /// 有效教学周范围文本，例如 "1-12"、"1-3,5-11,13-18"、"19"；空=每周
    var weekRangesText: String = ""
    var isEnabled: Bool
    var createdAt: Date

    init(weekday: Int,
         startMinutes: Int,
         endMinutes: Int,
         name: String,
         locationName: String = "",
         colorHex: String = "5E5CE6",
         weekParity: Int = 0,
         weekStart: Int = 1,
         weekEnd: Int = 18,
         weekRangesText: String = "",
         isEnabled: Bool = true) {
        self.id = UUID()
        self.weekday = weekday
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.name = name
        self.locationName = locationName
        self.colorHex = colorHex
        self.weekParity = weekParity
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.weekRangesText = weekRangesText
        self.isEnabled = isEnabled
        self.createdAt = .now
    }

    // MARK: - 周次计算

    /// 展开 `weekRangesText` 得到本学期内“有课”的教学周集合（已排序、去重）。
    var activeWeeks: [Int] {
        let text = weekRangesText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return Array(weekStart...max(weekEnd, weekStart)) }
        var weeks: Set<Int> = []
        for part in text.components(separatedBy: ",") where !part.isEmpty {
            let bounds = part.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            if bounds.count == 2,
               let a = Int(bounds[0]),
               let b = Int(bounds[1]),
               a > 0,
               b >= a {
                weeks.formUnion(a...b)
            } else if let a = Int(part), a > 0 {
                weeks.insert(a)
            }
        }
        return weeks.sorted()
    }

    /// 给定“当前教学周”（1 起），判断这门课当天是否上课。
    func isActive(onAcademicWeek week: Int) -> Bool {
        let text = weekRangesText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            switch weekParity {
            case 1: return week % 2 == 1
            case 2: return week % 2 == 0
            default: return true
            }
        }
        return activeWeeks.contains(week)
    }

    /// 课表/列表里的周次摘要，例如“1-12周”“1-3,5-11,13-18周”“19周”“单周”“每周”。
    var weekSummary: String {
        let text = weekRangesText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            return text.replacingOccurrences(of: "-", with: "‑") + "周"
        }
        switch weekParity {
        case 1: return "单周"
        case 2: return "双周"
        default: return "每周"
        }
    }
}
}

/// 业务代码始终使用最新 schema 中的课程类型。
typealias CourseEvent = LifeTrackSchemaV3.CourseEvent
