import SwiftUI
import SwiftData
import CoreLocation

struct PlaceDraft: Identifiable {
    let coordinate: CLLocationCoordinate2D
    let isCampusPlace: Bool

    init(coordinate: CLLocationCoordinate2D, isCampusPlace: Bool = false) {
        self.coordinate = coordinate
        self.isCampusPlace = isCampusPlace
    }

    var id: String { "\(coordinate.latitude),\(coordinate.longitude),\(isCampusPlace)" }
}

struct PlaceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let existingPlace: CustomPlace?
    @State private var selectedCoordinate: CLLocationCoordinate2D
    @State private var shortName = ""
    @State private var officialName = ""
    @State private var note = ""
    @State private var radius = 50.0
    @State private var category: PlaceCategory = .other
    @State private var symbolName = "mappin.circle.fill"
    @State private var isFavorite = false
    @State private var isAlwaysVisible = true
    @State private var isCampusPlace = false
    @State private var areaType: PlaceAreaType = .ordinary
    @State private var boundaryVertices: [CLLocationCoordinate2D] = []
    @State private var isDrawingBoundary = false
    @State private var isBoundaryClosed = false
    @State private var didLoadGeofence = false
    @State private var isLoadingAddress = false
    @State private var saveError: String?

    init(coordinate: CLLocationCoordinate2D, existingPlace: CustomPlace? = nil, defaultIsCampusPlace: Bool = false) {
        self.existingPlace = existingPlace
        _selectedCoordinate = State(initialValue: CLLocationCoordinate2D(latitude: existingPlace?.latitude ?? coordinate.latitude,
                                                                         longitude: existingPlace?.longitude ?? coordinate.longitude))
        _shortName = State(initialValue: existingPlace?.shortName ?? "")
        _officialName = State(initialValue: existingPlace?.officialName ?? "")
        _note = State(initialValue: existingPlace?.note ?? "")
        _radius = State(initialValue: existingPlace?.radius ?? 50)
        _category = State(initialValue: existingPlace?.category ?? .other)
        _symbolName = State(initialValue: existingPlace?.symbolName ?? "mappin.circle.fill")
        _isFavorite = State(initialValue: existingPlace?.isFavorite ?? false)
        _isAlwaysVisible = State(initialValue: existingPlace?.isAlwaysVisible ?? true)
        _isCampusPlace = State(initialValue: existingPlace?.isCampusPlace ?? defaultIsCampusPlace)
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
                    PlaceRadiusEditorMap(coordinate: $selectedCoordinate,
                                         radius: $radius,
                                         boundaryVertices: $boundaryVertices,
                                         isDrawingBoundary: $isDrawingBoundary,
                                         isBoundaryClosed: $isBoundaryClosed)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    Picker("边界方式", selection: $isDrawingBoundary) {
                        Text("圆形半径").tag(false)
                        Text("手绘区域").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: isDrawingBoundary) { _, drawing in
                        if !drawing {
                            boundaryVertices.removeAll()
                            isBoundaryClosed = false
                        }
                    }
                    if isDrawingBoundary {
                        HStack {
                            Button("撤销上一点") {
                                _ = boundaryVertices.popLast()
                                isBoundaryClosed = false
                            }
                                .disabled(boundaryVertices.isEmpty)
                            Spacer()
                            Button("清空", role: .destructive) {
                                boundaryVertices.removeAll()
                                isBoundaryClosed = false
                            }
                                .disabled(boundaryVertices.isEmpty)
                        }
                        Button {
                            isBoundaryClosed = true
                        } label: {
                            Label(isBoundaryClosed ? "边界已连接并闭合" : "按选点顺序连接并闭合",
                                  systemImage: isBoundaryClosed ? "checkmark.circle.fill" : "link")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(boundaryVertices.count < 3 || isBoundaryClosed)

                        Text(boundaryInstruction)
                            .font(.caption)
                            .foregroundStyle(isBoundaryClosed ? Color.secondary : Color.orange)
                    } else {
                        Text("长按地图或拖动标记可调整中心，蓝色范围圆就是自动打卡区域。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("坐标", value: String(format: "%.5f, %.5f", selectedCoordinate.latitude, selectedCoordinate.longitude))
                    if isLoadingAddress { ProgressView("正在查询地址") }
                    Button("使用反查地址名称") { lookupAddress() }
                }
                Section("识别") {
                    Picker("区域类型", selection: $areaType) {
                        ForEach(PlaceAreaType.allCases) { type in
                            Label(type.title, systemImage: type.symbolName).tag(type)
                        }
                    }
                    .onChange(of: areaType) { _, type in
                        guard type != .ordinary else { return }
                        category = type.defaultCategory
                        symbolName = type.symbolName
                        if type == .campus { isCampusPlace = true }
                    }
                    Toggle("设为校园地点", isOn: $isCampusPlace)
                    Picker("分类", selection: $category) {
                        ForEach(PlaceCategory.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("图标", selection: $symbolName) {
                        ForEach(["mappin.circle.fill", "graduationcap.fill", "building.columns.fill", "house.fill", "bed.double.fill", "book.closed.fill", "books.vertical.fill", "fork.knife", "cup.and.saucer.fill", "figure.run", "dumbbell.fill", "bus.fill"], id: \.self) { symbol in
                            Label(symbol.replacingOccurrences(of: ".fill", with: ""), systemImage: symbol).tag(symbol)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("识别半径：\(Int(radius)) 米")
                        Slider(value: $radius, in: 20...500, step: 5)
                    }
                    .disabled(isDrawingBoundary)
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
            .alert("地点未保存", isPresented: saveErrorPresented) {
                Button("好", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "请稍后重试。")
            }
        }
        .task { loadGeofenceIfNeeded() }
    }

    private func lookupAddress() {
        isLoadingAddress = true
        Task {
            let address = await GeocodingService().reverseGeocode(selectedCoordinate)
            await MainActor.run {
                if officialName.isEmpty { officialName = address ?? "" }
                isLoadingAddress = false
            }
        }
    }

    private func save() {
        if isDrawingBoundary && (boundaryVertices.count < 3 || !isBoundaryClosed) {
            saveError = boundaryVertices.count < 3
                ? "手绘区域至少需要 3 个边界点。"
                : "请先点击“按选点顺序连接并闭合”。"
            return
        }
        let savedPlace: CustomPlace
        if let existingPlace {
            existingPlace.shortName = shortName
            existingPlace.officialName = officialName.nilIfEmpty
            existingPlace.note = note.nilIfEmpty
            existingPlace.latitude = selectedCoordinate.latitude
            existingPlace.longitude = selectedCoordinate.longitude
            existingPlace.radius = radius
            existingPlace.categoryRawValue = category.rawValue
            existingPlace.symbolName = symbolName
            existingPlace.isFavorite = isFavorite
            existingPlace.isAlwaysVisible = isAlwaysVisible
            existingPlace.isCampusPlace = isCampusPlace
            existingPlace.updatedAt = .now
            savedPlace = existingPlace
        } else {
            let place = CustomPlace(shortName: shortName,
                                            officialName: officialName.nilIfEmpty,
                                            note: note.nilIfEmpty,
                                            latitude: selectedCoordinate.latitude,
                                            longitude: selectedCoordinate.longitude,
                                            radius: radius,
                                            category: category,
                                            symbolName: symbolName,
                                            isFavorite: isFavorite,
                                            isAlwaysVisible: isAlwaysVisible,
                                            isCampusPlace: isCampusPlace)
            modelContext.insert(place)
            savedPlace = place
        }
        saveGeofence(for: savedPlace.id)
        let saved = PersistenceService.save(modelContext,
                                            operation: "保存地点",
                                            failureRecovery: .rollback) { message in
            saveError = message
        }
        if saved {
            LocationService.shared.refreshPlaceCache()
            dismiss()
        }
    }

    private func loadGeofenceIfNeeded() {
        guard !didLoadGeofence else { return }
        didLoadGeofence = true
        guard let placeID = existingPlace?.id else {
            areaType = isCampusPlace ? .campus : .ordinary
            return
        }
        let descriptor = FetchDescriptor<PlaceGeofence>(predicate: #Predicate { $0.placeID == placeID })
        guard let geofence = try? modelContext.fetch(descriptor).first else { return }
        areaType = geofence.areaType
        boundaryVertices = geofence.vertices
        isDrawingBoundary = boundaryVertices.count >= 3
        isBoundaryClosed = boundaryVertices.count >= 3
    }

    private func saveGeofence(for placeID: UUID) {
        let descriptor = FetchDescriptor<PlaceGeofence>(predicate: #Predicate { $0.placeID == placeID })
        let existing = try? modelContext.fetch(descriptor).first
        let geofence = existing ?? PlaceGeofence(placeID: placeID)
        if existing == nil { modelContext.insert(geofence) }
        geofence.areaType = areaType
        geofence.vertices = isDrawingBoundary ? boundaryVertices : []
        geofence.updatedAt = .now
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(get: { saveError != nil },
                set: { if !$0 { saveError = nil } })
    }

    private var boundaryInstruction: String {
        if boundaryVertices.count < 3 {
            return "先在地图上选择至少 3 个边界点（当前 \(boundaryVertices.count) 个），选点阶段不会自动连线。"
        }
        if isBoundaryClosed {
            return "已按选点顺序连接最后一点与第一点；区域现在可以保存。"
        }
        return "边界点已选好。确认顺序后，手动点击上方按钮连接并闭合区域。"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
