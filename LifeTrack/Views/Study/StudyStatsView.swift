import SwiftUI
import SwiftData
import Charts

/// 学习统计：基于“学习教学”类地点的停留时长汇总，帮助复盘自习情况。
struct StudyStatsView: View {
    @Query(sort: \CustomPlace.shortName) private var places: [CustomPlace]
    @Query(sort: \StayRecord.arrivalTime, order: .reverse) private var stays: [StayRecord]

    private var studyPlaces: [CustomPlace] {
        places.filter { $0.category == .study }
    }

    private var studyStayIDs: Set<UUID> {
        Set(studyPlaces.map(\.id))
    }

    private var studyStays: [StayRecord] {
        stays.filter { $0.customPlaceID.map(studyStayIDs.contains) ?? false }
    }

    var body: some View {
        ScrollView {
            if studyPlaces.isEmpty {
                ContentUnavailableView("还没有学习地点",
                                       systemImage: "book.closed",
                                       description: Text("在地点页把图书馆、自习室、教室等标记为“学习教学”类别后，这里会统计你的学习时长。"))
                    .frame(maxWidth: .infinity, minHeight: 520)
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    summaryGrid
                    weeklyChart
                    placeBreakdown
                }
                .padding()
            }
        }
        .navigationTitle("学习统计")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryGrid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatisticTile(title: "今日学习", value: durationText(total(on: .now)), symbol: "clock.fill")
                StatisticTile(title: "本周学习", value: durationText(total(thisWeek: true)), symbol: "calendar")
            }
            GridRow {
                StatisticTile(title: "本月学习", value: durationText(total(thisWeek: false)), symbol: "calendar.badge.checkmark")
                StatisticTile(title: "学习停留", value: "\(studyStays.count)", symbol: "book.closed.fill")
            }
        }
    }

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近 7 天")
                .font(.headline)
            Chart(dailyStats) { stat in
                BarMark(
                    x: .value("日期", stat.date, unit: .day),
                    y: .value("分钟", stat.minutes)
                )
                .foregroundStyle(Color.indigo.gradient)
                .cornerRadius(4)
            }
            .frame(height: 180)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var placeBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("学习地点")
                .font(.headline)
            if placeSummaries.isEmpty {
                Text("还没有学习停留记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(placeSummaries) { summary in
                    HStack(spacing: 12) {
                        Image(systemName: summary.place.symbolName)
                            .foregroundStyle(.indigo)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.place.shortName)
                                .font(.subheadline.weight(.medium))
                            Text("\(summary.visitCount) 次停留")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(durationText(summary.totalDuration))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var dailyStats: [StudyDayStat] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let map = Dictionary(grouping: studyStays) { calendar.startOfDay(for: $0.arrivalTime) }
        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let seconds = (map[day] ?? []).reduce(0) { $0 + $1.duration }
            return StudyDayStat(date: day, minutes: seconds / 60)
        }
    }

    private var placeSummaries: [StudyPlaceSummary] {
        let groups = Dictionary(grouping: studyStays) { $0.customPlaceID }
        return groups.compactMap { id, stays in
            guard let id, let place = studyPlaces.first(where: { $0.id == id }) else { return nil }
            let total = stays.reduce(0) { $0 + $1.duration }
            return StudyPlaceSummary(place: place, visitCount: stays.count, totalDuration: total)
        }
        .sorted { $0.totalDuration > $1.totalDuration }
    }

    private func total(on day: Date) -> TimeInterval {
        let calendar = Calendar.current
        return studyStays
            .filter { calendar.isDate($0.arrivalTime, inSameDayAs: day) }
            .reduce(0) { $0 + $1.duration }
    }

    private func total(thisWeek: Bool) -> TimeInterval {
        let calendar = Calendar.current
        if thisWeek {
            let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .distantPast
            return studyStays.filter { $0.arrivalTime >= startOfWeek }.reduce(0) { $0 + $1.duration }
        }
        let startOfMonth = calendar.dateInterval(of: .month, for: .now)?.start ?? .distantPast
        return studyStays.filter { $0.arrivalTime >= startOfMonth }.reduce(0) { $0 + $1.duration }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        return "\(minutes)分钟"
    }
}

private struct StudyDayStat: Identifiable {
    let date: Date
    let minutes: Double
    var id: Date { date }
}

private struct StudyPlaceSummary: Identifiable {
    let place: CustomPlace
    let visitCount: Int
    let totalDuration: TimeInterval
    var id: UUID { place.id }
}
