import Foundation
import SwiftData

@Model
final class CustomPlace {
    @Attribute(.unique) var id: UUID
    var shortName: String
    var officialName: String?
    var note: String?
    var latitude: Double
    var longitude: Double
    var radius: Double
    var categoryRawValue: String
    var symbolName: String
    var isFavorite: Bool
    var isAlwaysVisible: Bool
    var priority: Int
    var createdAt: Date
    var updatedAt: Date

    init(shortName: String, officialName: String? = nil, note: String? = nil, latitude: Double, longitude: Double, radius: Double = 50, category: PlaceCategory = .other, symbolName: String = "mappin.circle.fill", isFavorite: Bool = false, isAlwaysVisible: Bool = true, priority: Int = 0) {
        self.id = UUID()
        self.shortName = shortName
        self.officialName = officialName
        self.note = note
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.categoryRawValue = category.rawValue
        self.symbolName = symbolName
        self.isFavorite = isFavorite
        self.isAlwaysVisible = isAlwaysVisible
        self.priority = priority
        self.createdAt = .now
        self.updatedAt = .now
    }

    var category: PlaceCategory { PlaceCategory(rawValue: categoryRawValue) ?? .other }
}

enum PlaceCategory: String, CaseIterable, Identifiable {
    case accommodation, study, dining, exercise, transport, other
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var defaultSymbol: String {
        switch self {
        case .accommodation: "house.fill"
        case .study: "book.closed.fill"
        case .dining: "fork.knife"
        case .exercise: "figure.run"
        case .transport: "bus.fill"
        case .other: "mappin.circle.fill"
        }
    }
}
