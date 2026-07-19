import SwiftUI
import PhotosUI
import CoreLocation
import ImageIO

struct PhotoTrackView: View {
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var photoPoints: [PhotoLocationPoint] = []
    @State private var skippedPhotoCount = 0
    @State private var isLoading = false
    @State private var cameraRequest: MapCameraRequest?

    private var mapPoints: [TrackMapPoint] {
        photoPoints.map {
            TrackMapPoint(coordinate: $0.coordinate,
                          timestamp: $0.date,
                          activityType: .unknown,
                          segmentID: 0,
                          horizontalAccuracy: 1,
                          source: .photo)
        }
    }

    private var totalDistance: Double {
        guard photoPoints.count > 1 else { return 0 }
        return zip(photoPoints, photoPoints.dropFirst()).reduce(0) { partial, pair in
            partial + CLLocation(latitude: pair.0.coordinate.latitude, longitude: pair.0.coordinate.longitude)
                .distance(from: CLLocation(latitude: pair.1.coordinate.latitude, longitude: pair.1.coordinate.longitude))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    photoTrackMap
                    controls
                    stats
                    pointList
                }
                .padding(.vertical)
            }
            .navigationTitle("照片轨迹")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $selectedItems, maxSelectionCount: 200, matching: .images) {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    .accessibilityLabel("选择照片")
                }
            }
            .onChange(of: selectedItems) { _, items in
                Task { await importLocations(from: items) }
            }
        }
    }

    private var photoTrackMap: some View {
        ZStack {
            if mapPoints.count > 1 {
                TrackMapView(points: mapPoints,
                             places: [],
                             currentLocation: nil,
                             cameraRequest: cameraRequest,
                             style: .vivid) { _ in }
                .frame(height: 460)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    Button {
                        cameraRequest = MapCameraRequest(target: .route)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
                    .padding(12)
                    .accessibilityLabel("适配全部照片轨迹")
                }
            } else {
                ContentUnavailableView("暂无照片轨迹", systemImage: "photo.badge.map", description: Text("选择带定位信息的照片后生成轨迹图。"))
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $selectedItems, maxSelectionCount: 200, matching: .images) {
                Label("选择照片", systemImage: "photo.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                selectedItems = []
                photoPoints = []
                skippedPhotoCount = 0
            } label: {
                Label("清空", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(photoPoints.isEmpty && selectedItems.isEmpty)
        }
        .padding(.horizontal)
    }

    private var stats: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatisticTile(title: "定位照片", value: "\(photoPoints.count)", symbol: "mappin.and.ellipse")
                StatisticTile(title: "连线距离", value: Formatters.distance(totalDistance), symbol: "point.3.connected.trianglepath.dotted")
            }
            GridRow {
                StatisticTile(title: "已跳过", value: "\(skippedPhotoCount)", symbol: "photo.badge.exclamationmark")
                StatisticTile(title: "状态", value: isLoading ? "读取中" : "完成", symbol: "checkmark.circle")
            }
        }
        .padding(.horizontal)
    }

    private var pointList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("定位点").font(.headline)
            if photoPoints.isEmpty {
                Text("没有读取到照片定位点。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(Array(photoPoints.enumerated()), id: \.element.id) { index, point in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.blue, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.date, format: .dateTime.month().day().hour().minute())
                                .font(.subheadline.weight(.semibold))
                            Text(String(format: "%.5f, %.5f", point.coordinate.latitude, point.coordinate.longitude))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(.horizontal)
    }

    @MainActor
    private func importLocations(from items: [PhotosPickerItem]) async {
        isLoading = true
        defer { isLoading = false }

        var importedPoints: [PhotoLocationPoint] = []
        var skipped = 0

        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let point = Self.locationPoint(from: data, fallbackIndex: index) else {
                skipped += 1
                continue
            }
            importedPoints.append(point)
        }

        photoPoints = importedPoints.sorted { $0.date < $1.date }
        skippedPhotoCount = skipped
        if photoPoints.count > 1 {
            cameraRequest = MapCameraRequest(target: .route)
        }
    }

    private static func locationPoint(from data: Data, fallbackIndex: Int) -> PhotoLocationPoint? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = coordinateValue(from: gps, valueKey: kCGImagePropertyGPSLatitude, refKey: kCGImagePropertyGPSLatitudeRef, negativeRef: "S"),
              let longitude = coordinateValue(from: gps, valueKey: kCGImagePropertyGPSLongitude, refKey: kCGImagePropertyGPSLongitudeRef, negativeRef: "W") else {
            return nil
        }

        let date = captureDate(from: properties) ?? Date(timeIntervalSince1970: TimeInterval(fallbackIndex))
        return PhotoLocationPoint(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), date: date)
    }

    private static func coordinateValue(from gps: [CFString: Any], valueKey: CFString, refKey: CFString, negativeRef: String) -> Double? {
        let rawValue = gps[valueKey]
        let value: Double?
        if let number = rawValue as? NSNumber {
            value = number.doubleValue
        } else if let string = rawValue as? String {
            value = Double(string)
        } else {
            value = nil
        }
        guard var coordinate = value else { return nil }
        if let ref = gps[refKey] as? String, ref.uppercased() == negativeRef {
            coordinate = -coordinate
        }
        return coordinate
    }

    private static func captureDate(from properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let dateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? properties[kCGImagePropertyTIFFDictionary].flatMap { ($0 as? [CFString: Any])?[kCGImagePropertyTIFFDateTime] as? String }
        guard let dateString else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: dateString)
    }
}

private struct PhotoLocationPoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let date: Date
}
