import SwiftUI
import SwiftData
import CoreLocation
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var locationService: LocationService
    @State private var preference: RecordingPreference = .smart
    @State private var sharedBackup: SharedFile?
    @State private var sharedDiagnostics: SharedFile?
    @State private var sharedDataFiles: [URL]?
    @State private var isSelectingBackup = false
    @State private var backupMessage: String?
    @State private var showBackupPrivacyWarning = false
    @State private var showOnboarding = false
    @State private var allowsCellularDownload = NetworkStatusService.allowsCellularPhotoDownload

    var body: some View {
        NavigationStack {
            Form {
                Section("定位权限") {
                    LabeledContent("状态", value: authorizationDescription)
                    if locationService.authorizationStatus == .notDetermined {
                        Button("允许使用 App 时定位") {
                            locationService.requestForegroundAuthorization()
                        }
                    } else if locationService.authorizationStatus == .authorizedWhenInUse {
                        Button("允许后台持续记录") {
                            locationService.requestBackgroundAuthorization()
                        }
                    } else if locationService.authorizationStatus == .denied ||
                                locationService.authorizationStatus == .restricted {
                        Button("打开系统设置") { openSystemSettings() }
                    }
                    if locationService.authorizationStatus == .authorizedWhenInUse {
                        Text("前台记录仍可使用；进入后台或锁屏后轨迹可能中断。升级为“始终允许”后，进行中的记录才能持续保存。")
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
                    NavigationLink {
                        DataHealthView()
                    } label: {
                        Label("数据健康", systemImage: "checkmark.shield")
                    }
                    Button {
                        showBackupPrivacyWarning = true
                    } label: {
                        Label("导出完整本地备份", systemImage: "externaldrive.badge.plus")
                    }
                    Button {
                        isSelectingBackup = true
                    } label: {
                        Label("从备份文件恢复", systemImage: "arrow.counterclockwise.icloud")
                    }
                    .disabled(locationService.activeSession != nil)
                    if locationService.activeSession != nil {
                        Text("请先结束当前轨迹记录，再恢复备份。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        exportCSV()
                    } label: {
                        Label("导出 CSV 数据", systemImage: "tablecells")
                    }
                    Button {
                        exportDiagnostics()
                    } label: {
                        Label("导出诊断报告", systemImage: "stethoscope")
                    }
                    Text("当前备份文件为本地明文备份，包含完整位置、活动、地点、Journey、旅行归档和照片分析记录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("网络与流量") {
                    Toggle("蜂窝网络下载照片缩略图", isOn: $allowsCellularDownload)
                        .onChange(of: allowsCellularDownload) { _, newValue in
                            NetworkStatusService.setAllowsCellularPhotoDownload(newValue)
                        }
                    Text("关闭后，蜂窝网络下不会从 iCloud 下载照片缩略图，仅在 Wi-Fi 下下载，避免消耗流量。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("照片隐私") {
                    Text("照片内容仅在设备本地进行分析；如果照片仅存储在 iCloud，系统可能从 iCloud 下载缩略图用于本地分析。LifeTrack 不会把原图上传到第三方服务器。")
                        .font(.footnote)
                }
                Section("AI 助手") {
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        Label("AI 助手（agnes-ai）", systemImage: "sparkles")
                    }
                    Text("接入免费 agnes-ai，支持整个 App 的记录问答与洞察。照片只提供本机脱敏后的类别和通用标签聚合，不发送图像、人物信息或敏感元数据。")
                        .font(.footnote)
                }
                Section("关于与帮助") {
                    LabeledContent("版本", value: "\(version) (\(build))")
                    Button {
                        showOnboarding = true
                    } label: {
                        Label("重新查看使用引导", systemImage: "book")
                    }
                    Button {
                        exportDiagnostics()
                    } label: {
                        Label("反馈问题（导出诊断报告）", systemImage: "envelope")
                    }
                }
                if let lastError = locationService.lastError {
                    Section("定位问题") { Text(lastError).foregroundStyle(.red) }
                }
            }
            .navigationTitle("设置")
            .onAppear { preference = locationService.recordingPreference }
            .sheet(item: $sharedBackup) { file in
                ShareSheet(items: [file.url])
            }
            .sheet(item: $sharedDiagnostics) { file in
                ShareSheet(items: [file.url])
            }
            .sheet(isPresented: dataFilesPresented) {
                ShareSheet(items: sharedDataFiles ?? [])
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView()
            }
            .fileImporter(isPresented: $isSelectingBackup,
                          allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let restored = try BackupService.restoreBackup(at: url, into: modelContext)
                    backupMessage = restored.totalInserted == 0
                        ? "备份中的数据均已存在，没有重复导入。"
                        : "恢复完成：新增 \(restored.insertedSessions) 条轨迹、\(restored.insertedTrackPoints) 个定位点、\(restored.insertedPlaces) 个地点和 \(restored.insertedStays) 条停留记录。"
                } catch {
                    backupMessage = error.localizedDescription
                }
            }
            .alert("本地备份", isPresented: backupMessagePresented) {
                Button("好", role: .cancel) { backupMessage = nil }
            } message: {
                Text(backupMessage ?? "")
            }
            .alert("备份包含敏感信息", isPresented: $showBackupPrivacyWarning) {
                Button("取消", role: .cancel) { }
                Button("继续导出", action: createBackup)
            } message: {
                Text("LifeTrack 备份包含完整位置、活动和地点数据，请妥善保管，不要发送给不可信的人。当前备份文件未加密。")
            }
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

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func createBackup() {
        do {
            sharedBackup = SharedFile(url: try BackupService.createBackup(from: modelContext))
        } catch {
            backupMessage = "创建备份失败：\(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        do {
            sharedDataFiles = try CSVExportService.exportAll(from: modelContext)
        } catch {
            backupMessage = "导出 CSV 失败：\(error.localizedDescription)"
        }
    }

    private func exportDiagnostics() {
        do {
            let health = try DataHealthService.inspect(context: modelContext)
            sharedDiagnostics = SharedFile(url: try DiagnosticsService.buildDiagnosticsReport(health: health))
        } catch {
            backupMessage = "导出诊断报告失败：\(error.localizedDescription)"
        }
    }

    private var backupMessagePresented: Binding<Bool> {
        Binding(get: { backupMessage != nil },
                set: { if !$0 { backupMessage = nil } })
    }

    private var dataFilesPresented: Binding<Bool> {
        Binding(get: { sharedDataFiles != nil },
                set: { if !$0 { sharedDataFiles = nil } })
    }
}
