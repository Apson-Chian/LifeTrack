import Foundation
import SwiftData

@Model
final class DailySummary {
    @Attribute(.unique) var id: UUID
    var date: Date
    var totalDistance: Double
    var walkingDistance: Double
    var runningDistance: Double
    var cyclingDistance: Double
    var automotiveDistance: Double
    var activeDuration: TimeInterval
    var stayCount: Int

    init(date: Date) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.totalDistance = 0
        self.walkingDistance = 0
        self.runningDistance = 0
        self.cyclingDistance = 0
        self.automotiveDistance = 0
        self.activeDuration = 0
        self.stayCount = 0
    }
}
