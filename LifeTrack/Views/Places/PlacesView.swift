import SwiftUI
import SwiftData
import CoreLocation

struct PlacesView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var locationService: LocationService
    @Query(sort: \CustomPlace.shortName) private var places: [CustomPlace]
    @Query(sort: \StayRecord.arrivalTime, order: .reverse) private var stays: [StayRecord]
    @State private var searchText = ""
    @State private var draft: PlaceDraft?
    @State private var editingPlace: CustomPlace?
    @State private var persistenceError: String?

    private var filteredPlaces: [CustomPlace] {
        searchText.isEmpty ? places : places.filter { $0.shortName.localizedCaseInsensitiveContains(searchText) || ($0.officialName?.localizedCaseInsensitiveContains(searchText) ?? false) }
    }

    private var campusPlaces: [CustomPlace] {
        places.filter(\.isCampusPlace)
    }

    private var campusSemesterAnalytics: CampusAnalytics {
        CampusAnalytics(places: campusPlaces, stays: stays, scope: .semester)
    }

    private var allCampusAnalytics: CampusAnalytics {
        CampusAnalytics(places: campusPlaces, stays: stays, scope: .all)
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
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
                    }
                }

                if !places.filter(\.isFavorite).isEmpty {
                    Section("收藏地点") {
                        ForEach(places.filter(\.isFavorite)) { placeRow($0) }
                        .onDelete(perform: deleteFavorites)
                    }
                }
                Section("全部地点") {
                    ForEach(filteredPlaces) { placeRow($0) }
                    .onDelete(perform: delete)
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
                    .disabled(locationService.currentLocation == nil)
                }
            }
            .overlay {
                if places.isEmpty {
                    ContentUnavailableView("暂无地点", systemImage: "mappin.slash", description: Text("可以标记当前位置，或在地图上长按添加地点。"))
                }
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
                        if place.isCampusPlace {
                            Text("校园")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.indigo)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.indigo.opacity(0.1), in: Capsule())
                        }
                    }
                    if let officialName = place.officialName { Text(officialName).font(.caption).foregroundStyle(.secondary) }
                    if let summary = campusSummary(for: place), summary.visitCount > 0 {
                        Text("\(summary.visitCount) 次打卡 · \(Formatters.duration(summary.totalDuration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(Int(place.radius)) m").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func campusSummary(for place: CustomPlace) -> CampusPlaceSummary? {
        guard place.isCampusPlace else { return nil }
        return allCampusAnalytics.placeSummaries.first { $0.place.id == place.id }
    }

    private func addPlace(isCampusPlace: Bool) {
        guard let coordinate = locationService.currentLocation?.coordinate else { return }
        draft = PlaceDraft(coordinate: coordinate, isCampusPlace: isCampusPlace)
    }

    private func delete(at offsets: IndexSet) {
        let values = filteredPlaces
        for index in offsets { modelContext.delete(values[index]) }
        savePlaceDeletion(operation: "删除地点")
    }

    private func deleteFavorites(at offsets: IndexSet) {
        let values = places.filter(\.isFavorite)
        for index in offsets { modelContext.delete(values[index]) }
        savePlaceDeletion(operation: "删除收藏地点")
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
