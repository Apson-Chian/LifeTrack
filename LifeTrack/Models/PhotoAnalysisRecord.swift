import Foundation
import SwiftData

@Model
final class PhotoAnalysisRecord {
    @Attribute(.unique) var assetIdentifier: String
    var creationDate: Date
    var latitude: Double?
    var longitude: Double?
    var originalLatitude: Double?
    var originalLongitude: Double?
    var primaryCategoryRawValue: String
    var categoryRawValues: String
    var topLabelsRawValue: String
    var confidence: Double
    var faceCount: Int
    var analysisStateRawValue: String
    var analyzedAt: Date
    var linkedSessionID: UUID?

    init(assetIdentifier: String,
         creationDate: Date,
         latitude: Double? = nil,
         longitude: Double? = nil,
         originalLatitude: Double? = nil,
         originalLongitude: Double? = nil,
         categories: [PhotoSmartCategory],
         topLabels: [String],
         confidence: Double,
         faceCount: Int,
         state: PhotoAnalysisState,
         linkedSessionID: UUID? = nil) {
        self.assetIdentifier = assetIdentifier
        self.creationDate = creationDate
        self.latitude = latitude
        self.longitude = longitude
        self.originalLatitude = originalLatitude
        self.originalLongitude = originalLongitude
        self.primaryCategoryRawValue = (categories.first ?? .other).rawValue
        self.categoryRawValues = categories.map(\.rawValue).joined(separator: ",")
        self.topLabelsRawValue = topLabels.joined(separator: "\n")
        self.confidence = confidence
        self.faceCount = faceCount
        self.analysisStateRawValue = state.rawValue
        self.analyzedAt = .now
        self.linkedSessionID = linkedSessionID
    }

    var primaryCategory: PhotoSmartCategory {
        PhotoSmartCategory(rawValue: primaryCategoryRawValue) ?? .other
    }

    var categories: [PhotoSmartCategory] {
        categoryRawValues
            .split(separator: ",")
            .compactMap { PhotoSmartCategory(rawValue: String($0)) }
    }

    var topLabels: [String] {
        topLabelsRawValue.split(separator: "\n").map(String.init)
    }

    var analysisState: PhotoAnalysisState {
        PhotoAnalysisState(rawValue: analysisStateRawValue) ?? .failed
    }

    func update(categories: [PhotoSmartCategory],
                topLabels: [String],
                confidence: Double,
                faceCount: Int,
                state: PhotoAnalysisState,
                linkedSessionID: UUID?) {
        primaryCategoryRawValue = (categories.first ?? .other).rawValue
        categoryRawValues = categories.map(\.rawValue).joined(separator: ",")
        topLabelsRawValue = topLabels.joined(separator: "\n")
        self.confidence = confidence
        self.faceCount = faceCount
        analysisStateRawValue = state.rawValue
        analyzedAt = .now
        self.linkedSessionID = linkedSessionID
    }
}

enum PhotoAnalysisState: String, Codable {
    case completed
    case thumbnailUnavailable
    case failed
}

enum PhotoSmartCategory: String, CaseIterable, Identifiable, Codable {
    case landscape
    case architecture
    case food
    case people
    case animal
    case plant
    case sport
    case selfie
    case night
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .landscape: "风景"
        case .architecture: "建筑"
        case .food: "美食"
        case .people: "人物"
        case .animal: "动物"
        case .plant: "植物"
        case .sport: "运动"
        case .selfie: "自拍"
        case .night: "夜景"
        case .other: "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .landscape: "mountain.2.fill"
        case .architecture: "building.2.fill"
        case .food: "fork.knife"
        case .people: "person.2.fill"
        case .animal: "pawprint.fill"
        case .plant: "leaf.fill"
        case .sport: "figure.run"
        case .selfie: "person.crop.square.fill"
        case .night: "moon.stars.fill"
        case .other: "square.grid.2x2.fill"
        }
    }
}
