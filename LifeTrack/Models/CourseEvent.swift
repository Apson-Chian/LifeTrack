import Foundation
import SwiftData

/// 一条课程安排。用于课表展示与“上课中”状态判断。
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
    /// 单双周：0=每周，1=单周，2=双周
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
