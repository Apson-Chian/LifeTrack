import SwiftUI
import SwiftData
import CoreLocation

struct PlacesView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var locationService: LocationService
    @Query(sort: \CustomPlace.shortName) private var places: [CustomPlace]
    @State private var searchText = ""
    @State private var draft: PlaceDraft?
    @State private var editingPlace: CustomPlace?

    private var filteredPlaces: [CustomPlace] {
        searchText.isEmpty ? places : places.filter { $0.shortName.localizedCaseInsensitiveContains(searchText) || ($0.officialName?.localizedCaseInsensitiveContains(searchText) ?? false) }
    }

    var body: some View {
        NavigationStack {
            List {
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
                    Button {
                        guard let coordinate = locationService.currentLocation?.coordinate else { return }
                        draft = PlaceDraft(coordinate: coordinate)
                    } label: { Image(systemName: "plus") }
                    .disabled(locationService.currentLocation == nil)
                }
            }
            .overlay {
                if places.isEmpty {
                    ContentUnavailableView("暂无地点", systemImage: "mappin.slash", description: Text("可以标记当前位置，或在地图上长按添加地点。"))
                }
            }
            .sheet(item: $draft) { draft in PlaceEditorView(coordinate: draft.coordinate) }
            .sheet(item: $editingPlace) { place in PlaceEditorView(coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), existingPlace: place) }
        }
    }

    private func placeRow(_ place: CustomPlace) -> some View {
        Button { editingPlace = place } label: {
            HStack {
                Image(systemName: place.symbolName).foregroundStyle(.tint).frame(width: 25)
                VStack(alignment: .leading) {
                    Text(place.shortName).foregroundStyle(.primary)
                    if let officialName = place.officialName { Text(officialName).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text("\(Int(place.radius)) m").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let values = filteredPlaces
        for index in offsets { modelContext.delete(values[index]) }
        try? modelContext.save()
    }

    private func deleteFavorites(at offsets: IndexSet) {
        let values = places.filter(\.isFavorite)
        for index in offsets { modelContext.delete(values[index]) }
        try? modelContext.save()
    }
}
