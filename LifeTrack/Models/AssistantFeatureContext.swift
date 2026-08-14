import Foundation

/// 从具体业务页面进入助手时携带的轻量上下文。
/// 这里只描述当前功能，不携带照片、坐标或其他原始记录；实际数据仍由受限工具按需读取。
enum AssistantFeatureContext: String, Identifiable, CaseIterable {
    case general
    case today
    case activity
    case places
    case schedule
    case photos
    case travel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "记录问答"
        case .today: "今日助手"
        case .activity: "运动助手"
        case .places: "地点助手"
        case .schedule: "课表助手"
        case .photos: "照片回忆助手"
        case .travel: "旅行助手"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "sparkles"
        case .today: "sun.max.fill"
        case .activity: "figure.run"
        case .places: "mappin.and.ellipse"
        case .schedule: "calendar"
        case .photos: "photo.on.rectangle.angled"
        case .travel: "suitcase.rolling.fill"
        }
    }

    var instruction: String {
        switch self {
        case .general:
            "用户从助手主页提问。请在整个 LifeTrack 的可用记录中选择相关工具。"
        case .today:
            "用户正在查看今日页面。优先结合今天的运动、轨迹和停留记录回答。"
        case .activity:
            "用户正在查看运动与轨迹。优先结合运动类型、距离、时长和出行记录回答。"
        case .places:
            "用户正在查看地点。优先结合地点类别、到访次数和停留时长回答。"
        case .schedule:
            "用户正在查看课表。优先结合课程、学习地点停留和运动恢复情况回答。"
        case .photos:
            "用户正在查看照片智能整理。只能使用经过脱敏聚合的照片分类与通用标签回答。"
        case .travel:
            "用户正在查看旅行归档。优先结合已确认旅行、出行、地点和脱敏照片摘要回答。"
        }
    }

    var suggestedQuestions: [String] {
        switch self {
        case .general:
            ["最近一周我的生活节奏怎么样？", "我最近运动和学习平衡吗？", "根据所有记录给我一个小建议"]
        case .today:
            ["我今天运动得怎么样？", "今天去了哪些地方？", "和最近一周相比，今天活动量如何？"]
        case .activity:
            ["我最近最常做什么运动？", "近一个月运动量有什么变化？", "我的运动时长和距离是否匹配？"]
        case .places:
            ["我最近最常去哪些地方？", "我在哪些地方停留最久？", "最近的地点节奏有什么变化？"]
        case .schedule:
            ["这周课程和运动怎么安排更合理？", "我的学习停留时间够吗？", "哪些天的课程最紧张？"]
        case .photos:
            ["最近照片主要记录了什么？", "我的照片分类有什么变化？", "结合脱敏照片摘要回顾最近生活"]
        case .travel:
            ["帮我总结最近一次旅行", "我的旅行通常有哪些特点？", "结合旅行和运动记录写一段回忆"]
        }
    }
}

struct AssistantConversationTurn: Sendable {
    let question: String
    let answer: String
}
