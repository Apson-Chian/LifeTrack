import SwiftUI
import SwiftData
import MapKit

/// 校园热点热力图：按校园地点的停留频次/时长渲染成半透明圆，颜色越深代表去得越多。
struct CampusHeatmapView: View {
    @Query(sort: \CustomPlace.shortName) private var places: [CustomPlace]
    @Query(sort: \StayRecord.arrivalTime, order: .reverse) private var stays: [StayRecord]

    private var campusPlaces: [CustomPlace] {
        places.filter(\.isCampusPlace)
    }

    private var hotspots: [CampusHotspot] {
        let groups = Dictionary(grouping: stays) { $0.customPlaceID }
        return campusPlaces.compactMap { place in
            let placeStays = groups[place.id] ?? []
            guard !placeStays.isEmpty else { return nil }
            let visitCount = placeStays.count
            let totalDuration = placeStays.reduce(0) { $0 + $1.duration }
            return CampusHotspot(place: place, visitCount: visitCount, totalDuration: totalDuration)
        }
        .sorted { $0.visitCount > $1.visitCount }
    }

    var body: some View {
        Group {
            if hotspots.isEmpty {
                ContentUnavailableView("暂无热点数据",
                                       systemImage: "flame",
                                       description: Text("在校园地点产生停留记录后，这里会生成活动热力图。"))
                    .frame(maxWidth: .infinity, minHeight: 520)
            } else {
                heatmap
            }
        }
        .navigationTitle("校园热力图")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var heatmap: some View {
        ZStack(alignment: .bottom) {
            Map(initialPosition: initialPosition) {
                ForEach(hotspots) { hotspot in
                    MapCircle(center: hotspot.coordinate, radius: hotspot.radius)
                        .foregroundStyle(hotspot.color.opacity(hotspot.opacity))
                        .stroke(hotspot.color.opacity(0.55), lineWidth: 1)
                }
            }

            legend
                .padding(12)
        }
    }

    private var initialPosition: MapCameraPosition {
        guard let first = hotspots.first else {
            return .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 32.06, longitude: 118.79),
                latitudinalMeters: 1_200, longitudinalMeters: 1_200))
        }
        return .region(MKCoordinateRegion(center: first.coordinate,
                                          latitudinalMeters: 1_400, longitudinalMeters: 1_400))
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Text("少")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .fill(Color.indigo.opacity(0.15 + Double(index) * 0.18))
                    .frame(width: 14, height: 14)
            }
            Text("多")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct CampusHotspot: Identifiable {
    let place: CustomPlace
    let visitCount: Int
    let totalDuration: TimeInterval

    var id: UUID { place.id }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }

    /// 半径随停留时长增长，方便直观比较常驻程度。
    var radius: CLLocationDistance {
        max(place.radius, 40 + min(totalDuration / 60, 240))
    }

    /// 颜色随到访次数加深。
    var color: Color {
        .indigo
    }

    var opacity: Double {
        min(0.15 + Double(visitCount) * 0.12, 0.85)
    }
}
