import SwiftUI
import SwiftData
import MapKit

struct CampusDashboardView: View {
    @Query(sort: \CustomPlace.shortName) private var allPlaces: [CustomPlace]
    @Query(sort: \StayRecord.arrivalTime, order: .reverse) private var allStays: [StayRecord]
    @Query private var geofences: [PlaceGeofence]
    @State private var scope: CampusSummaryScope = .semester

    private var campusPlaces: [CustomPlace] {
        allPlaces.filter(\.isCampusPlace)
    }

    private var analytics: CampusAnalytics {
        CampusAnalytics(places: campusPlaces, stays: allStays, scope: scope)
    }

    var body: some View {
        ScrollView {
            if campusPlaces.isEmpty {
                ContentUnavailableView("还没有校园地点",
                                       systemImage: "graduationcap",
                                       description: Text("在地点页点击右上角 +，选择“添加校园地点”，并在地图上划定打卡范围。"))
                    .frame(maxWidth: .infinity, minHeight: 520)
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    CampusOverviewMap(places: campusPlaces, geofences: geofences)
                        .frame(height: 290)
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    Picker("统计时间", selection: $scope) {
                        ForEach(CampusSummaryScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)

                    summaryGrid
                    checkInSummary
                    placeStatistics

                    if !analytics.recentCheckIns.isEmpty {
                        recentCheckIns
                    }
                }
                .padding()
            }
        }
        .navigationTitle("校园足迹")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryGrid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatisticTile(title: "打卡次数", value: "\(analytics.totalVisitCount)", symbol: "checkmark.seal.fill")
                StatisticTile(title: "已去地点", value: "\(analytics.visitedPlaceCount)/\(campusPlaces.count)", symbol: "building.2.fill")
            }
            GridRow {
                StatisticTile(title: "校园停留", value: analytics.compactDurationText, symbol: "clock.fill")
                StatisticTile(title: "活跃天数", value: "\(analytics.activeDayCount)", symbol: "calendar.badge.checkmark")
            }
        }
    }

    private var checkInSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("打卡总结", systemImage: "graduationcap.fill")
                .font(.headline)
                .foregroundStyle(.white)

            Text(analytics.summaryText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            if !analytics.achievements.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(analytics.achievements) { achievement in
                            Label(achievement.title, systemImage: achievement.symbolName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.white.opacity(0.16), in: Capsule())
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            LinearGradient(colors: [Color.indigo, Color.blue.opacity(0.82)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    private var placeStatistics: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("校园地点")
                    .font(.headline)
                Spacer()
                Text("次数 · 停留")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(analytics.placeSummaries) { summary in
                NavigationLink {
                    CampusPlaceDetailView(summary: summary)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: summary.place.symbolName)
                            .foregroundStyle(summary.visitCount > 0 ? Color.indigo : Color.secondary)
                            .frame(width: 42, height: 42)
                            .background((summary.visitCount > 0 ? Color.indigo : Color.secondary).opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.place.shortName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(summary.place.category.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(summary.visitCount == 0 ? "未打卡" : "\(summary.visitCount) 次")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(summary.visitCount == 0 ? "--" : Formatters.duration(summary.totalDuration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentCheckIns: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近打卡")
                .font(.headline)

            ForEach(analytics.recentCheckIns.prefix(8)) { checkIn in
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(checkIn.place.shortName)
                            .font(.subheadline.weight(.semibold))
                        Text(checkIn.stay.arrivalTime.formatted(.dateTime.month().day().weekday(.wide).hour().minute()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Formatters.duration(CampusAnalytics.effectiveDuration(of: checkIn.stay)))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct CampusPlaceDetailView: View {
    let summary: CampusPlaceSummary

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: summary.place.symbolName)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.place.shortName)
                            .font(.headline)
                        Text("\(summary.place.category.displayName) · \(Int(summary.place.radius)) 米打卡范围")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("统计") {
                LabeledContent("到访次数", value: "\(summary.visitCount) 次")
                LabeledContent("累计停留", value: Formatters.duration(summary.totalDuration))
                LabeledContent("平均停留", value: Formatters.duration(summary.averageDuration))
                if let lastVisit = summary.lastVisit {
                    LabeledContent("最近到访", value: lastVisit.formatted(.dateTime.year().month().day().hour().minute()))
                }
            }

            Section("打卡记录") {
                if summary.stays.isEmpty {
                    Text("还没有进入过该地点的打卡范围。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summary.stays.sorted { $0.arrivalTime > $1.arrivalTime }) { stay in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(stay.arrivalTime.formatted(.dateTime.year().month().day().weekday(.wide)))
                                    .font(.subheadline.weight(.semibold))
                                Text(stayTime(stay))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Formatters.duration(CampusAnalytics.effectiveDuration(of: stay)))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(summary.place.shortName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stayTime(_ stay: StayRecord) -> String {
        let arrival = stay.arrivalTime.formatted(.dateTime.hour().minute())
        guard let departure = stay.departureTime else { return "\(arrival) 起 · 正在打卡" }
        return "\(arrival)–\(departure.formatted(.dateTime.hour().minute()))"
    }
}

enum CampusSummaryScope: String, CaseIterable, Identifiable {
    case week
    case month
    case semester
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "本周"
        case .month: "本月"
        case .semester: "本学期"
        case .all: "全部"
        }
    }

    func includes(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch self {
        case .week:
            return date >= (calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now)
        case .month:
            return date >= (calendar.dateInterval(of: .month, for: now)?.start ?? now)
        case .semester:
            return date >= semesterStart(now: now, calendar: calendar)
        case .all:
            return true
        }
    }

    private func semesterStart(now: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: now)
        let year = components.year ?? 2000
        let month = components.month ?? 1
        if month >= 8 {
            return calendar.date(from: DateComponents(year: year, month: 8, day: 1)) ?? now
        }
        if month == 1 {
            return calendar.date(from: DateComponents(year: year - 1, month: 8, day: 1)) ?? now
        }
        return calendar.date(from: DateComponents(year: year, month: 2, day: 1)) ?? now
    }
}

struct CampusPlaceSummary: Identifiable {
    let place: CustomPlace
    let stays: [StayRecord]
    var id: UUID { place.id }
    var visitCount: Int { stays.count }
    var totalDuration: TimeInterval { stays.reduce(0) { $0 + CampusAnalytics.effectiveDuration(of: $1) } }
    var averageDuration: TimeInterval { visitCount == 0 ? 0 : totalDuration / Double(visitCount) }
    var lastVisit: Date? { stays.map(\.arrivalTime).max() }
}

struct CampusCheckIn: Identifiable {
    let stay: StayRecord
    let place: CustomPlace
    var id: UUID { stay.id }
}

struct CampusAnalytics {
    let placeSummaries: [CampusPlaceSummary]
    let recentCheckIns: [CampusCheckIn]

    init(places: [CustomPlace], stays: [StayRecord], scope: CampusSummaryScope) {
        let scopedStays = stays.filter { scope.includes($0.arrivalTime) }
        var staysByPlaceID: [UUID: [StayRecord]] = [:]
        var checkIns: [CampusCheckIn] = []

        for stay in scopedStays {
            guard let place = Self.matchedPlace(for: stay, among: places) else { continue }
            staysByPlaceID[place.id, default: []].append(stay)
            checkIns.append(CampusCheckIn(stay: stay, place: place))
        }

        placeSummaries = places
            .map { CampusPlaceSummary(place: $0, stays: staysByPlaceID[$0.id] ?? []) }
            .sorted {
                if $0.visitCount == $1.visitCount {
                    if $0.totalDuration == $1.totalDuration {
                        return $0.place.shortName < $1.place.shortName
                    }
                    return $0.totalDuration > $1.totalDuration
                }
                return $0.visitCount > $1.visitCount
            }
        recentCheckIns = checkIns.sorted { $0.stay.arrivalTime > $1.stay.arrivalTime }
    }

    var totalVisitCount: Int { placeSummaries.reduce(0) { $0 + $1.visitCount } }
    var visitedPlaceCount: Int { placeSummaries.filter { $0.visitCount > 0 }.count }
    var totalDuration: TimeInterval { placeSummaries.reduce(0) { $0 + $1.totalDuration } }
    var activeDayCount: Int {
        Set(recentCheckIns.map { Calendar.current.startOfDay(for: $0.stay.arrivalTime) }).count
    }

    var compactDurationText: String {
        if totalDuration >= 3_600 {
            return String(format: "%.1f小时", totalDuration / 3_600)
        }
        return Formatters.duration(totalDuration)
    }

    var summaryText: String {
        guard totalVisitCount > 0 else {
            return "还没有校园打卡记录。开始记录轨迹后，进入已划定的校园范围会自动生成打卡。"
        }
        let mostVisited = placeSummaries.first { $0.visitCount > 0 }
        let longest = placeSummaries.filter { $0.visitCount > 0 }.max { $0.totalDuration < $1.totalDuration }
        var text = "在 \(visitedPlaceCount) 个校园地点完成了 \(totalVisitCount) 次打卡，累计停留 \(Formatters.duration(totalDuration))。"
        if let mostVisited {
            text += " 最常去的是“\(mostVisited.place.shortName)”（\(mostVisited.visitCount) 次）。"
        }
        if let longest, longest.id != mostVisited?.id {
            text += " 停留最久的是“\(longest.place.shortName)”。"
        }
        return text
    }

    var achievements: [CampusAchievement] {
        var result: [CampusAchievement] = []
        if visitedPlaceCount >= 5 {
            result.append(CampusAchievement(title: "校园探索者", symbolName: "map.fill"))
        }
        if placeSummaries.contains(where: { $0.place.category == .study && $0.visitCount >= 10 }) {
            result.append(CampusAchievement(title: "自习达人", symbolName: "books.vertical.fill"))
        }
        if placeSummaries.contains(where: { $0.place.category == .exercise && $0.visitCount >= 8 }) {
            result.append(CampusAchievement(title: "运动健将", symbolName: "figure.run"))
        }
        if totalDuration >= 40 * 3_600 {
            result.append(CampusAchievement(title: "校园常驻", symbolName: "clock.badge.checkmark.fill"))
        }
        if result.isEmpty, totalVisitCount > 0 {
            result.append(CampusAchievement(title: "校园初印记", symbolName: "sparkles"))
        }
        return result
    }

    static func effectiveDuration(of stay: StayRecord, now: Date = .now) -> TimeInterval {
        guard stay.departureTime == nil,
              now.timeIntervalSince(stay.arrivalTime) <= 24 * 60 * 60 else {
            return max(stay.duration, 0)
        }
        return max(stay.duration, now.timeIntervalSince(stay.arrivalTime))
    }

    private static func matchedPlace(for stay: StayRecord, among places: [CustomPlace]) -> CustomPlace? {
        if let customPlaceID = stay.customPlaceID {
            return places.first { $0.id == customPlaceID }
        }

        let stayLocation = CLLocation(latitude: stay.latitude, longitude: stay.longitude)
        return places
            .map { place in
                (place, stayLocation.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)))
            }
            .filter { $0.1 <= $0.0.radius }
            .min { $0.1 < $1.1 }?
            .0
    }
}

struct CampusAchievement: Identifiable {
    let title: String
    let symbolName: String
    var id: String { title }
}

private struct CampusOverviewMap: UIViewRepresentable {
    let places: [CustomPlace]
    let geofences: [PlaceGeofence]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .includingAll
        map.showsCompass = true
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        map.removeOverlays(map.overlays)

        let geofenceByPlaceID = Dictionary(uniqueKeysWithValues: geofences.map { ($0.placeID, $0) })
        for place in places {
            let annotation = CampusPlaceAnnotation(place: place)
            map.addAnnotation(annotation)
            if var vertices = geofenceByPlaceID[place.id]?.vertices, vertices.count >= 3 {
                map.addOverlay(MKPolygon(coordinates: &vertices, count: vertices.count))
            } else {
                map.addOverlay(MKCircle(center: annotation.coordinate, radius: place.radius))
            }
        }

        let signature = places.map { "\($0.id):\($0.latitude):\($0.longitude):\($0.radius)" }.joined(separator: "|")
        guard context.coordinator.lastSignature != signature else { return }
        context.coordinator.lastSignature = signature
        let visibleRect = map.overlays.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
        if !visibleRect.isNull {
            map.setVisibleMapRect(visibleRect,
                                  edgePadding: UIEdgeInsets(top: 54, left: 38, bottom: 54, right: 38),
                                  animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastSignature: String?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer: MKOverlayPathRenderer
            if let circle = overlay as? MKCircle {
                renderer = MKCircleRenderer(circle: circle)
            } else if let polygon = overlay as? MKPolygon {
                renderer = MKPolygonRenderer(polygon: polygon)
            } else {
                return MKOverlayRenderer(overlay: overlay)
            }
            renderer.strokeColor = .systemIndigo
            renderer.fillColor = UIColor.systemIndigo.withAlphaComponent(0.12)
            renderer.lineWidth = 1.5
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let campusAnnotation = annotation as? CampusPlaceAnnotation else { return nil }
            let identifier = "CampusPlace"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.markerTintColor = .systemIndigo
            view.glyphImage = UIImage(systemName: campusAnnotation.symbolName)
            view.glyphTintColor = .white
            view.canShowCallout = true
            return view
        }
    }
}

private final class CampusPlaceAnnotation: MKPointAnnotation {
    let symbolName: String

    init(place: CustomPlace) {
        symbolName = place.symbolName
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        title = place.shortName
        subtitle = "\(place.category.displayName) · \(Int(place.radius)) 米"
    }
}
