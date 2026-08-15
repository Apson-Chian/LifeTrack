import SwiftUI
import SwiftData
import CoreLocation

struct PlacesView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var locationService: LocationService
    @Query(sort: \CustomPlace.shortName) private var places: [CustomPlace]
    @Query private var geofences: [PlaceGeofence]
    @Query(sort: \StayRecord.arrivalTime, order: .reverse) private var stays: [StayRecord]
    @State private var searchText = ""
    @State private var draft: PlaceDraft?
    @State private var editingPlace: CustomPlace?
    @State private var persistenceError: String?
    @State private var pendingPlaceFromCurrentLocation = false

    private var filteredPlaces: [CustomPlace] {
        searchText.isEmpty ? places : places.filter { $0.shortName.localizedCaseInsensitiveContains(searchText) || ($0.officialName?.localizedCaseInsensitiveContains(searchText) ?? false) }
    }

    private var campusPlaces: [CustomPlace] {
        places.filter(isCampusLife)
    }

    private var entertainmentPlaces: [CustomPlace] {
        places.filter { !isCampusLife($0) }
    }

    private var campusSemesterAnalytics: CampusAnalytics {
        CampusAnalytics(places: campusPlaces, stays: stays, scope: .semester)
    }

    private var allCampusAnalytics: CampusAnalytics {
        CampusAnalytics(places: campusPlaces, stays: stays, scope: .all)
    }

    private var geofenceByPlaceID: [UUID: PlaceGeofence] {
        Dictionary(uniqueKeysWithValues: geofences.map { ($0.placeID, $0) })
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    Section {
                        Button {
                            addPlace(isCampusPlace: false)
                        } label: {
                            Label(pendingPlaceFromCurrentLocation ? "正在获取当前位置…" : "添加地点并划定范围",
                                  systemImage: "mappin.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(pendingPlaceFromCurrentLocation)
                    } footer: {
                        Text("可从当前位置开始，再在编辑器中长按地图移动中心或手绘边界。今日与历史轨迹地图也支持长按添加。")
                    }

                    Section("校园生活") {
                        NavigationLink {
                            CampusDashboardView()
                        } label: {
                            campusEntryRow
                        }

                        NavigationLink {
                            TimetableView()
                        } label: {
                            campusFeatureRow(symbol: "calendar", tint: .blue,
                                             title: "课表",
                                             subtitle: "管理每周课程安排")
                        }

                        NavigationLink {
                            StudyStatsView()
                        } label: {
                            campusFeatureRow(symbol: "book.closed.fill", tint: .teal,
                                             title: "学习统计",
                                             subtitle: "汇总图书馆、自习室等学习停留时长")
                        }

                        NavigationLink {
                            CampusHeatmapView()
                        } label: {
                            campusFeatureRow(symbol: "flame.fill", tint: .orange,
                                             title: "校园热力图",
                                             subtitle: "查看校园活动热点分布")
                        }

                        ForEach(campusPlaces) { placeRow($0) }
                            .onDelete { deletePlaces(campusPlaces, at: $0, operation: "删除校园地点") }

                        Button { addPlace(isCampusPlace: true) } label: {
                            Label("添加校园附近地点", systemImage: "graduationcap.fill")
                        }
                    }

                    Section {
                        if entertainmentPlaces.isEmpty {
                            Text("校园范围之外的地点会归入这里。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(entertainmentPlaces) { placeRow($0) }
                                .onDelete { deletePlaces(entertainmentPlaces, at: $0, operation: "删除娱乐地点") }
                        }
                        Button { addPlace(isCampusPlace: false) } label: {
                            Label("添加娱乐生活地点", systemImage: "party.popper.fill")
                        }
                    } header: {
                        Text("娱乐生活")
                    } footer: {
                        Text("位于校园边界内或校园约 1.5 公里内的地点自动归为校园生活，其他地点归为娱乐生活。")
                    }
                } else {
                    Section("搜索结果") {
                    ForEach(filteredPlaces) { placeRow($0) }
                            .onDelete { deletePlaces(filteredPlaces, at: $0, operation: "删除地点") }
                    }
                }
            }
            .navigationTitle("地点")
            .searchable(text: $searchText, prompt: "搜索地点")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    AssistantToolbarLink(context: .places)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            addPlace(isCampusPlace: true)
                        } label: {
                            Label("添加校园地点", systemImage: "graduationcap.fill")
                        }
                        Button {
                            addPlace(isCampusPlace: false)
                        } label: {
                            Label("添加普通地点", systemImage: "mappin.circle.fill")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onChange(of: locationService.currentLocation) { _, location in
                guard pendingPlaceFromCurrentLocation,
                      let coordinate = location?.coordinate else { return }
                pendingPlaceFromCurrentLocation = false
                draft = PlaceDraft(coordinate: coordinate)
            }
            .sheet(item: $draft) { draft in
                PlaceEditorView(coordinate: draft.coordinate, defaultIsCampusPlace: draft.isCampusPlace)
            }
            .sheet(item: $editingPlace) { place in PlaceEditorView(coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), existingPlace: place) }
            .alert("地点操作失败", isPresented: persistenceErrorPresented) {
                Button("好", role: .cancel) { persistenceError = nil }
            } message: {
                Text(persistenceError ?? "请稍后重试。")
            }
        }
    }

    private var campusEntryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "graduationcap.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 4) {
                Text("校园足迹与打卡")
                    .font(.subheadline.weight(.semibold))
                if campusPlaces.isEmpty {
                    Text("添加宿舍、教学楼、食堂等校园地点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("本学期 \(campusSemesterAnalytics.totalVisitCount) 次打卡 · \(campusSemesterAnalytics.compactDurationText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func campusFeatureRow(symbol: String,
                                  tint: Color,
                                  title: String,
                                  subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func placeRow(_ place: CustomPlace) -> some View {
        Button { editingPlace = place } label: {
            HStack {
                Image(systemName: place.symbolName).foregroundStyle(.tint).frame(width: 25)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(place.shortName).foregroundStyle(.primary)
                        if place.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                        if isCampusLife(place) {
                            Text("校园生活")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.indigo)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.indigo.opacity(0.1), in: Capsule())
                        }
                    }
                    if let officialName = place.officialName { Text(officialName).font(.caption).foregroundStyle(.secondary) }
                    if let geofence = geofenceByPlaceID[place.id] {
                        Label(geofence.vertices.count >= 3 ? "\(geofence.areaType.title) · 手绘边界" : geofence.areaType.title,
                              systemImage: geofence.areaType.symbolName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let summary = campusSummary(for: place), summary.visitCount > 0 {
                        Text("\(summary.visitCount) 次打卡 · \(Formatters.duration(summary.totalDuration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text((geofenceByPlaceID[place.id]?.vertices.count ?? 0) >= 3 ? "自定义" : "\(Int(place.radius)) m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func campusSummary(for place: CustomPlace) -> CampusPlaceSummary? {
        guard isCampusLife(place) else { return nil }
        return allCampusAnalytics.placeSummaries.first { $0.place.id == place.id }
    }

    private func addPlace(isCampusPlace: Bool) {
        if let coordinate = locationService.currentLocation?.coordinate {
            draft = PlaceDraft(coordinate: coordinate, isCampusPlace: isCampusPlace)
        } else {
            pendingPlaceFromCurrentLocation = true
            locationService.requestCurrentLocation()
        }
    }

    private func deletePlaces(_ values: [CustomPlace], at offsets: IndexSet, operation: String) {
        for index in offsets { deletePlaceAndGeofence(values[index]) }
        savePlaceDeletion(operation: operation)
    }

    private func isCampusLife(_ place: CustomPlace) -> Bool {
        if place.isCampusPlace || geofenceByPlaceID[place.id]?.areaType == .campus { return true }
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        return places.contains { campus in
            guard campus.id != place.id,
                  campus.isCampusPlace || geofenceByPlaceID[campus.id]?.areaType == .campus else { return false }
            if PlaceGeofenceGeometry.contains(location.coordinate,
                                               place: campus,
                                               geofence: geofenceByPlaceID[campus.id]) {
                return true
            }
            return location.distance(from: CLLocation(latitude: campus.latitude,
                                                      longitude: campus.longitude)) <= campus.radius + 1_500
        }
    }

    private func deletePlaceAndGeofence(_ place: CustomPlace) {
        if let geofence = geofenceByPlaceID[place.id] { modelContext.delete(geofence) }
        modelContext.delete(place)
    }

    private func savePlaceDeletion(operation: String) {
        let saved = PersistenceService.save(modelContext,
                                            operation: operation,
                                            failureRecovery: .rollback) {
            persistenceError = $0
        }
        if saved { locationService.refreshPlaceCache() }
    }

    private var persistenceErrorPresented: Binding<Bool> {
        Binding(get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } })
    }
}
