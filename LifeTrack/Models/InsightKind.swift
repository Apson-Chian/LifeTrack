import Foundation

/// AI 洞察类型，也作为 LifeInsightRecord 的分类字段。
enum InsightKind: String, Codable, CaseIterable, Identifiable {
    case dailyReflection = "dailyReflection"
    case weeklyReview = "weeklyReview"
    case learningLifeBalance = "learningLifeBalance"
    case travelStory = "travelStory"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dailyReflection: "今日回顾"
        case .weeklyReview: "本周复盘"
        case .learningLifeBalance: "学娱平衡"
        case .travelStory: "旅行手记"
        case .custom: "自定义洞察"
        }
    }

    var symbol: String {
        switch self {
        case .dailyReflection: "sun.max.fill"
        case .weeklyReview: "calendar.badge.clock"
        case .learningLifeBalance: "figure.mind.and.body"
        case .travelStory: "airplane.departure"
        case .custom: "sparkles"
        }
    }
}
