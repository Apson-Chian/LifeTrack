import SwiftUI
import SwiftData
import CoreLocation

struct PlaceDraft: Identifiable {
    let coordinate: CLLocationCoordinate2D
    var id: String { "\(coordinate.latitude),\(coordinate.longitude)" }
}

struct PlaceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let coordinate: CLLocationCoordinate2D
    let existingPlace: CustomPlace?
    @State private var shortName = ""
    @State private var officialName = ""
    @State private var note = ""
    @State private var radius = 50.0
    @State private var category: PlaceCategory = .other
    @State private var symbolName = "mappin.circle.fill"
    @State private var isFavorite = false
    @State private var isAlwaysVisible = true
    @State private var isLoadingAddress = false

    init(coordinate: CLLocationCoordinate2D, existingPlace: CustomPlace? = nil) {
        self.coordinate = coordinate
        self.existingPlace = existingPlace
        _shortName = State(initialValue: existingPlace?.shortName ?? "")
        _officialName = State(initialValue: existingPlace?.officialName ?? "")
        _note = State(initialValue: existingPlace?.note ?? "")
        _radius = State(initialValue: existingPlace?.radius ?? 50)
        _category = State(initialValue: existingPlace?.category ?? .other)
        _symbolName = State(initialValue: existingPlace?.symbolName ?? "mappin.circle.fill")
        _isFavorite = State(initialValue: existingPlace?.isFavorite ?? false)
        _isAlwaysVisible = State(initialValue: existingPlace?.isAlwaysVisible ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("简称", text: $shortName)
                    TextField("完整名称", text: $officialName)
                    TextField("备注", text: $note, axis: .vertical)
                }
                Section("位置") {
                    LabeledContent("坐标", value: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    if isLoadingAddress { ProgressView("正在查询地址") }
                    Button("使用反查地址名称") { lookupAddress() }
                }
                Section("识别") {
                    Picker("分类", selection: $category) {
                        ForEach(PlaceCategory.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("图标", selection: $symbolName) {
                        ForEach(["mappin.circle.fill", "house.fill", "book.closed.fill", "fork.knife", "figure.run", "bus.fill"], id: \.self) { symbol in
                            Label(symbol.replacingOccurrences(of: ".fill", with: ""), systemImage: symbol).tag(symbol)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("识别半径：\(Int(radius)) 米")
                        Slider(value: $radius, in: 20...300, step: 5)
                    }
                }
                Section {
                    Toggle("收藏", isOn: $isFavorite)
                    Toggle("始终显示在地图上", isOn: $isAlwaysVisible)
                }
            }
            .navigationTitle(existingPlace == nil ? "新建地点" : "编辑地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(shortName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func lookupAddress() {
        isLoadingAddress = true
        Task {
            let address = await GeocodingService().reverseGeocode(coordinate)
            await MainActor.run {
                if officialName.isEmpty { officialName = address ?? "" }
                isLoadingAddress = false
            }
        }
    }

    private func save() {
        if let existingPlace {
            existingPlace.shortName = shortName
            existingPlace.officialName = officialName.nilIfEmpty
            existingPlace.note = note.nilIfEmpty
            existingPlace.radius = radius
            existingPlace.categoryRawValue = category.rawValue
            existingPlace.symbolName = symbolName
            existingPlace.isFavorite = isFavorite
            existingPlace.isAlwaysVisible = isAlwaysVisible
            existingPlace.updatedAt = .now
        } else {
            modelContext.insert(CustomPlace(shortName: shortName,
                                            officialName: officialName.nilIfEmpty,
                                            note: note.nilIfEmpty,
                                            latitude: coordinate.latitude,
                                            longitude: coordinate.longitude,
                                            radius: radius,
                                            category: category,
                                            symbolName: symbolName,
                                            isFavorite: isFavorite,
                                            isAlwaysVisible: isAlwaysVisible))
        }
        try? modelContext.save()
        dismiss()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
