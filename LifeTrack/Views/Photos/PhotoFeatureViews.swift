import SwiftUI
import Photos
import CoreLocation

struct PhotoAssetRecord: Identifiable {
    let id: String
    let date: Date
    let coordinate: CLLocationCoordinate2D?
    var linkedSessionID: UUID? = nil
}

struct PhotoFeatureRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let value: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            if let value {
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct PhotoFeatureTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct PhotoPlacesView: View {
    let groups: [PhotoLocationGroup]

    @State private var selectedGroupID: String?
    @State private var resolvedNames: [String: String] = [:]
    @State private var cameraRequest: MapCameraRequest?
    @State private var selectedPhoto: PhotoDetailItem?
    @State private var hiddenAssetIdentifiers: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 180), spacing: 4)]

    init(points: [PhotoLocationPoint]) {
        let groups = PhotoLocationGroup.build(from: points)
        self.groups = groups
        _selectedGroupID = State(initialValue: groups.first?.id)
    }

    private var selectedGroup: PhotoLocationGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    private var selectedMapPoints: [TrackMapPoint] {
        visiblePhotos.map(\.mapPoint)
    }

    private var visiblePhotos: [PhotoLocationPoint] {
        (selectedGroup?.photos ?? [])
            .filter { !hiddenAssetIdentifiers.contains($0.id) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            if let selectedGroup {
                VStack(alignment: .leading, spacing: 16) {
                    TrackMapView(points: selectedMapPoints,
                                 places: [],
                                 currentLocation: nil,
                                 cameraRequest: cameraRequest,
                                 style: .photoDots) { _ in }
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(alignment: .topLeading) {
                            Label(displayName(for: selectedGroup), systemImage: "mappin.and.ellipse")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(12)
                        }

                    locationSelector

                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName(for: selectedGroup))
                                .font(.title3.weight(.semibold))
                            Text(selectedGroup.dateRangeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(visiblePhotos.count) 张")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(visiblePhotos) { photo in
                            Button {
                                selectedPhoto = PhotoDetailItem(assetIdentifier: photo.id,
                                                                creationDate: photo.date,
                                                                coordinate: photo.originalCoordinate)
                            } label: {
                                PhotoGridThumbnail(assetIdentifier: photo.id)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看 \(photo.date.formatted(date: .abbreviated, time: .shortened)) 的照片")
                        }
                    }
                }
                .padding()
            } else {
                ContentUnavailableView("暂无地点照片",
                                       systemImage: "photo.badge.exclamationmark",
                                       description: Text("带有位置信息的照片会按拍摄地点显示在这里。"))
                    .frame(minHeight: 420)
            }
        }
        .navigationTitle("地点相册")
        .navigationBarTitleDisplayMode(.inline)
        .task { await resolveGroupNames() }
        .onChange(of: selectedGroupID) { _, _ in
            cameraRequest = MapCameraRequest(target: .route)
        }
        .onAppear {
            if !selectedMapPoints.isEmpty {
                cameraRequest = MapCameraRequest(target: .route)
            }
        }
        .sheet(item: $selectedPhoto) { item in
            PhotoDetailView(item: item) { identifier in
                hiddenAssetIdentifiers.insert(identifier)
            }
        }
    }

    private var locationSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groups) { group in
                    Button {
                        selectedGroupID = group.id
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(for: group))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("\(visiblePhotoCount(for: group)) 张")
                                .font(.caption)
                                .foregroundStyle(selectedGroupID == group.id ? .white.opacity(0.8) : .secondary)
                        }
                        .foregroundStyle(selectedGroupID == group.id ? .white : .primary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(selectedGroupID == group.id ? Color.accentColor : Color(uiColor: .secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func displayName(for group: PhotoLocationGroup) -> String {
        resolvedNames[group.id] ?? group.fallbackName
    }

    private func visiblePhotoCount(for group: PhotoLocationGroup) -> Int {
        group.photos.lazy.filter { !hiddenAssetIdentifiers.contains($0.id) }.count
    }

    private func resolveGroupNames() async {
        let geocoder = GeocodingService()
        for group in groups.prefix(40) where resolvedNames[group.id] == nil {
            guard !Task.isCancelled else { return }
            if let name = await geocoder.reverseGeocode(group.geocodingCoordinate), !name.isEmpty {
                resolvedNames[group.id] = name
            }
        }
    }
}

struct PhotoLocationGalleryView: View {
    let title: String
    let points: [PhotoLocationPoint]

    @State private var selectedPhoto: PhotoDetailItem?
    @State private var hiddenAssetIdentifiers: Set<String> = []
    @State private var cameraRequest: MapCameraRequest?

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 180), spacing: 4)]

    private var visiblePoints: [PhotoLocationPoint] {
        points
            .filter { !hiddenAssetIdentifiers.contains($0.id) }
            .sorted { $0.date > $1.date }
    }

    private var mapPoints: [TrackMapPoint] {
        visiblePoints.map(\.mapPoint)
    }

    private var dateRangeText: String {
        guard let first = visiblePoints.last?.date,
              let last = visiblePoints.first?.date else { return "--" }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return first.formatted(.dateTime.year().month().day())
        }
        return "\(first.formatted(.dateTime.year().month().day())) – \(last.formatted(.dateTime.year().month().day()))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !mapPoints.isEmpty {
                    TrackMapView(points: mapPoints,
                                 places: [],
                                 currentLocation: nil,
                                 cameraRequest: cameraRequest,
                                 style: .photoDots) { _ in }
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                        Text(dateRangeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(visiblePoints.count) 张")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(visiblePoints) { photo in
                        Button {
                            selectedPhoto = PhotoDetailItem(assetIdentifier: photo.id,
                                                            creationDate: photo.date,
                                                            coordinate: photo.originalCoordinate)
                        } label: {
                            PhotoGridThumbnail(assetIdentifier: photo.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !mapPoints.isEmpty {
                cameraRequest = MapCameraRequest(target: .route)
            }
        }
        .sheet(item: $selectedPhoto) { item in
            PhotoDetailView(item: item) { identifier in
                hiddenAssetIdentifiers.insert(identifier)
            }
        }
    }
}

struct PhotoFootprintView: View {
    let points: [PhotoLocationPoint]

    @State private var selectedYear: Int?
    @State private var cameraRequest: MapCameraRequest?

    private var years: [Int] {
        Array(Set(points.map { Calendar.current.component(.year, from: $0.date) })).sorted(by: >)
    }

    private var filteredPoints: [PhotoLocationPoint] {
        guard let selectedYear else { return points }
        return points.filter { Calendar.current.component(.year, from: $0.date) == selectedYear }
    }

    private var mapPoints: [TrackMapPoint] {
        filteredPoints.map(\.mapPoint)
    }

    private var groups: [PhotoLocationGroup] {
        PhotoLocationGroup.build(from: filteredPoints)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TrackMapView(points: mapPoints,
                             places: [],
                             currentLocation: nil,
                             cameraRequest: cameraRequest,
                             style: .photoDots) { _ in }
                    .frame(height: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            cameraRequest = MapCameraRequest(target: .route)
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.body.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                    }

                Picker("年份", selection: $selectedYear) {
                    Text("全部年份").tag(Optional<Int>.none)
                    ForEach(years, id: \.self) { year in
                        Text(String(year)).tag(Optional(year))
                    }
                }
                .pickerStyle(.menu)

                Grid(horizontalSpacing: 10) {
                    GridRow {
                        StatisticTile(title: "足迹数", value: "\(filteredPoints.count)", symbol: "shoeprints.fill")
                        StatisticTile(title: "拍摄地", value: "\(groups.count)", symbol: "mappin.and.ellipse")
                    }
                }

                if !groups.isEmpty {
                    Text("常去的足迹")
                        .font(.headline)
                    ForEach(Array(groups.prefix(8).enumerated()), id: \.element.id) { index, group in
                        NavigationLink {
                            PhotoLocationGalleryView(title: group.fallbackName,
                                                     points: group.photos)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Color.teal.gradient, in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.fallbackName)
                                        .font(.subheadline.weight(.semibold))
                                    Text(group.dateRangeText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(group.photos.count) 张")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("足迹图")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !mapPoints.isEmpty {
                cameraRequest = MapCameraRequest(target: .route)
            }
        }
        .onChange(of: selectedYear) { _, _ in
            cameraRequest = MapCameraRequest(target: .route)
        }
    }
}

private struct LegacyPhotoTravelTimelineView: View {
    let assets: [PhotoAssetRecord]

    private var yearGroups: [PhotoTimelineYear] {
        PhotoTimelineYear.build(from: assets)
    }

    private var activeDayCount: Int {
        Set(assets.map { Calendar.current.startOfDay(for: $0.date) }).count
    }

    private var spanText: String {
        guard let first = assets.min(by: { $0.date < $1.date })?.date,
              let last = assets.max(by: { $0.date < $1.date })?.date else { return "--" }
        return "\(first.formatted(.dateTime.year().month())) – \(last.formatted(.dateTime.year().month()))"
    }

    var body: some View {
        ScrollView {
            if assets.isEmpty {
                ContentUnavailableView("暂无旅行时间轴",
                                       systemImage: "calendar.badge.exclamationmark",
                                       description: Text("有拍摄时间的照片会自动按年、月和日排列。"))
                    .frame(minHeight: 420)
            } else {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    timelineSummary
                        .padding(.bottom, 18)

                    ForEach(yearGroups) { yearGroup in
                        Section {
                            ForEach(yearGroup.days) { day in
                                PhotoTimelineDayRow(day: day)
                            }
                        } header: {
                            Text(String(yearGroup.year))
                                .font(.title2.weight(.bold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                                .background(.background)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("旅行时间轴")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var timelineSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("从第一张到现在")
                .font(.headline)
            Text(spanText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Grid(horizontalSpacing: 10) {
                GridRow {
                    StatisticTile(title: "时间轴照片", value: "\(assets.count)", symbol: "photo.stack")
                    StatisticTile(title: "拍摄日", value: "\(activeDayCount)", symbol: "calendar")
                }
            }
        }
        .padding(.top)
    }
}

private struct PhotoTimelineDayRow: View {
    let day: PhotoTimelineDay

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.orange.opacity(0.25), lineWidth: 6))
                Rectangle()
                    .fill(Color.orange.opacity(0.22))
                    .frame(width: 2, height: 132)
            }
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(day.date.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(.headline)
                    Spacer()
                    Text("\(day.assets.count) 张")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if day.locatedCount > 0 {
                    Label("\(day.locatedCount) 张带有地点信息", systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if day.linkedSessionCount > 0 {
                    Label("关联 \(day.linkedSessionCount) 段运动轨迹", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption)
                        .foregroundStyle(.indigo)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(day.assets.prefix(12)) { asset in
                            PhotoThumbnailView(assetIdentifier: asset.id, cornerRadius: 8)
                                .frame(width: 86, height: 86)
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }
}

struct PhotoThumbnailView: View {
    let assetIdentifier: String
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear(perform: requestImage)
        .onDisappear {
            if requestID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
        .accessibilityLabel("照片缩略图")
    }

    private func requestImage() {
        guard image == nil,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestImage(for: asset,
                                                          targetSize: CGSize(width: 360, height: 360),
                                                          contentMode: .aspectFill,
                                                          options: options) { result, _ in
            guard let result else { return }
            DispatchQueue.main.async {
                image = result
            }
        }
    }
}

struct PhotoLocationGroup: Identifiable {
    let id: String
    let center: CLLocationCoordinate2D
    let geocodingCoordinate: CLLocationCoordinate2D
    let photos: [PhotoLocationPoint]
    let fallbackName: String

    var dateRangeText: String {
        guard let first = photos.min(by: { $0.date < $1.date })?.date,
              let last = photos.max(by: { $0.date < $1.date })?.date else { return "--" }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return first.formatted(.dateTime.year().month().day())
        }
        return "\(first.formatted(.dateTime.year().month().day())) – \(last.formatted(.dateTime.year().month().day()))"
    }

    static func build(from points: [PhotoLocationPoint]) -> [PhotoLocationGroup] {
        let cellSize = 0.018
        var clusters: [PhotoLocationCluster] = []
        var clusterIndexesByCell: [PhotoLocationCell: [Int]] = [:]

        for point in points.sorted(by: { $0.date < $1.date }) {
            let cell = PhotoLocationCell(coordinate: point.coordinate, size: cellSize)
            var nearestIndex: Int?
            var nearestDistance = CLLocationDistance.greatestFiniteMagnitude

            for neighbor in cell.neighbors {
                for index in clusterIndexesByCell[neighbor] ?? [] {
                    let distance = clusters[index].distance(to: point.coordinate)
                    if distance <= 1_200, distance < nearestDistance {
                        nearestIndex = index
                        nearestDistance = distance
                    }
                }
            }

            if let nearestIndex {
                clusters[nearestIndex].add(point)
            } else {
                clusters.append(PhotoLocationCluster(point: point))
                clusterIndexesByCell[cell, default: []].append(clusters.count - 1)
            }
        }

        return clusters
            .sorted {
                if $0.photos.count == $1.photos.count {
                    return ($0.photos.last?.date ?? .distantPast) > ($1.photos.last?.date ?? .distantPast)
                }
                return $0.photos.count > $1.photos.count
            }
            .enumerated()
            .map { index, cluster in
                PhotoLocationGroup(id: cluster.photos.first?.id ?? UUID().uuidString,
                                   center: cluster.center,
                                   geocodingCoordinate: cluster.geocodingCenter,
                                   photos: cluster.photos,
                                   fallbackName: "地点 \(index + 1)")
            }
    }
}

private struct PhotoLocationCell: Hashable {
    let latitude: Int
    let longitude: Int

    init(coordinate: CLLocationCoordinate2D, size: Double) {
        latitude = Int(floor(coordinate.latitude / size))
        longitude = Int(floor(coordinate.longitude / size))
    }

    private init(latitude: Int, longitude: Int) {
        self.latitude = latitude
        self.longitude = longitude
    }

    var neighbors: [PhotoLocationCell] {
        (-1...1).flatMap { latitudeOffset in
            (-1...1).map { longitudeOffset in
                PhotoLocationCell(latitude: latitude + latitudeOffset, longitude: longitude + longitudeOffset)
            }
        }
    }
}

private struct PhotoLocationCluster {
    private var latitudeSum: Double
    private var longitudeSum: Double
    private var originalLatitudeSum: Double
    private var originalLongitudeSum: Double
    private(set) var photos: [PhotoLocationPoint]

    init(point: PhotoLocationPoint) {
        latitudeSum = point.coordinate.latitude
        longitudeSum = point.coordinate.longitude
        originalLatitudeSum = point.originalCoordinate.latitude
        originalLongitudeSum = point.originalCoordinate.longitude
        photos = [point]
    }

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitudeSum / Double(photos.count),
                               longitude: longitudeSum / Double(photos.count))
    }

    var geocodingCenter: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: originalLatitudeSum / Double(photos.count),
                               longitude: originalLongitudeSum / Double(photos.count))
    }

    mutating func add(_ point: PhotoLocationPoint) {
        latitudeSum += point.coordinate.latitude
        longitudeSum += point.coordinate.longitude
        originalLatitudeSum += point.originalCoordinate.latitude
        originalLongitudeSum += point.originalCoordinate.longitude
        photos.append(point)
    }

    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: center.latitude, longitude: center.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}

private struct PhotoTimelineYear: Identifiable {
    let year: Int
    let days: [PhotoTimelineDay]
    var id: Int { year }

    static func build(from assets: [PhotoAssetRecord], calendar: Calendar = .current) -> [PhotoTimelineYear] {
        let days = Dictionary(grouping: assets) { calendar.startOfDay(for: $0.date) }
            .map { date, assets in
                PhotoTimelineDay(date: date, assets: assets.sorted { $0.date > $1.date })
            }
            .sorted { $0.date > $1.date }

        return Dictionary(grouping: days) { calendar.component(.year, from: $0.date) }
            .map { year, days in PhotoTimelineYear(year: year, days: days.sorted { $0.date > $1.date }) }
            .sorted { $0.year > $1.year }
    }
}

private struct PhotoTimelineDay: Identifiable {
    let date: Date
    let assets: [PhotoAssetRecord]
    var id: Date { date }
    var locatedCount: Int { assets.filter { $0.coordinate != nil }.count }
    var linkedSessionCount: Int { Set(assets.compactMap(\.linkedSessionID)).count }
}

private extension PhotoLocationPoint {
    var mapPoint: TrackMapPoint {
        TrackMapPoint(coordinate: coordinate,
                      timestamp: date,
                      activityType: .unknown,
                      segmentID: 0,
                      horizontalAccuracy: 1,
                      source: .photo)
    }
}
