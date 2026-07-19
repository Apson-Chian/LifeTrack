import Foundation

enum Formatters {
    static func distance(_ meters: Double) -> String {
        meters >= 1_000 ? String(format: "%.2f 公里", meters / 1_000) : String(format: "%.0f 米", meters)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(Int(seconds.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)小时\(minutes)分钟" : "\(hours)小时"
        }
        if minutes > 0 {
            return remainingSeconds > 0 ? "\(minutes)分钟\(remainingSeconds)秒" : "\(minutes)分钟"
        }
        return "\(remainingSeconds)秒"
    }

    static func pace(distance: Double, duration: TimeInterval) -> String {
        guard distance > 0 else { return "--" }
        let secondsPerKilometer = max(Int((duration / (distance / 1_000)).rounded()), 0)
        let minutes = secondsPerKilometer / 60
        let seconds = secondsPerKilometer % 60
        return String(format: "%d分%02d秒/公里", minutes, seconds)
    }
}
