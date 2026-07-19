import SwiftUI
import CoreLocation

struct SettingsView: View {
    @ObservedObject var locationService: LocationService
    @State private var preference: RecordingPreference = .smart

    var body: some View {
        NavigationStack {
            Form {
                Section("定位权限") {
                    LabeledContent("状态", value: authorizationDescription)
                    Button(locationService.authorizationStatus == .notDetermined ? "允许定位访问" : "请求始终允许") {
                        locationService.requestAuthorization()
                    }
                    if locationService.authorizationStatus == .authorizedWhenInUse {
                        Text("始终允许后，正在进行的记录可以在后台继续保存轨迹。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("记录") {
                    Picker("记录模式", selection: $preference) {
                        ForEach(RecordingPreference.allCases) { Text($0.displayName).tag($0) }
                    }
                    .onChange(of: preference) { _, newValue in
                        locationService.recordingPreference = newValue
                        locationService.savePreference()
                    }
                    Text(preferenceDescription).font(.footnote).foregroundStyle(.secondary)
                }
                Section("数据") {
                    Text("LifeTrack 只在本机保存定位点、运动记录、地点和停留信息，不使用账号或服务器。")
                        .font(.footnote)
                }
                if let lastError = locationService.lastError {
                    Section("定位问题") { Text(lastError).foregroundStyle(.red) }
                }
            }
            .navigationTitle("设置")
            .onAppear { preference = locationService.recordingPreference }
        }
    }

    private var authorizationDescription: String {
        switch locationService.authorizationStatus {
        case .authorizedAlways: "始终允许"
        case .authorizedWhenInUse: "使用期间允许"
        case .denied: "已拒绝"
        case .restricted: "受限制"
        case .notDetermined: "未决定"
        @unknown default: "未知"
        }
    }

    private var preferenceDescription: String {
        switch preference {
        case .smart: "根据运动状态自动调整定位精度和记录频率。"
        case .batterySaver: "使用更少、精度较低的定位点，延长续航。"
        case .precise: "使用高精度和高频率定位点，耗电会更高。"
        }
    }
}
