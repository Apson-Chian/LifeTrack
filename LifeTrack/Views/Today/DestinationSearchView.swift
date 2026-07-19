import SwiftUI
import MapKit

struct NavigationDestination: Identifiable {
    let name: String
    let coordinate: CLLocationCoordinate2D
    var id: String { "\(name)-\(coordinate.latitude)-\(coordinate.longitude)" }
}

struct DestinationSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [NavigationDestination] = []
    let onSelect: (NavigationDestination) -> Void

    var body: some View {
        NavigationStack {
            List(results) { result in
                Button {
                    onSelect(result)
                    dismiss()
                } label: {
                    Label(result.name, systemImage: "mappin")
                }
            }
            .overlay {
                if !query.isEmpty && results.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle("目的地")
            .searchable(text: $query, prompt: "搜索地图")
            .onChange(of: query) { _, newValue in search(newValue) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func search(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { results = []; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        MKLocalSearch(request: request).start { response, _ in
            results = response?.mapItems.compactMap { item in
                guard let name = item.name else { return nil }
                return NavigationDestination(name: name, coordinate: item.placemark.coordinate)
            } ?? []
        }
    }
}
