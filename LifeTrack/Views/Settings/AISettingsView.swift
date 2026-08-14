import SwiftUI

/// AI 助手设置：开启 agnes-ai、填写 API Key（存于 Keychain）、选择模型、测试连接。
struct AISettingsView: View {
    @State private var isEnabled = AgnesSettings.isEnabled
    @State private var apiKeyText: String
    @State private var model = AgnesSettings.model
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testFailed = false
    @State private var showTestAlert = false

    private let models = ["agnes-2.5-flash", "agnes-2.0-flash"]

    init() {
        _apiKeyText = State(initialValue: AgnesSettings.apiKey ?? "")
        _model = State(initialValue: AgnesSettings.model)
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用 AI 助手", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        AgnesSettings.setEnabled(newValue)
                    }
                SecureField("Agnes API Key", text: $apiKeyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKeyText) { _, newValue in
                        AgnesSettings.setApiKey(newValue)
                    }
                Picker("模型", selection: $model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: model) { _, newValue in
                    AgnesSettings.setModel(newValue)
                }
                Button { testConnection() } label: {
                    Label("测试连接", systemImage: "bolt.fill")
                }
                .disabled(isTesting || apiKeyText.isEmpty)
            } header: {
                Text("AI 助手（agnes-ai）")
            } footer: {
                Text("API Key 仅保存在本机 Keychain，不会写入源码或普通设置。免费额度有限（文本约 20 次/分钟），请合理使用。")
                    .font(.footnote)
            }

            Section("隐私说明") {
                Text("AI 无权读取你的照片。原图、缩略图、照片标识符、位置元数据、本机分析标签和照片统计都不会发送给 Agnes。AI 仅能通过受限工具读取活动、停留、课表和旅行归档等文字/数值数据。")
                    .font(.footnote)
            }

            Section("关于") {
                LabeledContent("网关", value: "apihub.agnes-ai.com")
                LabeledContent("状态", value: AgnesSettings.isConfigured ? "已配置" : "未配置")
                Link("agnes-ai 官网", destination: URL(string: "https://agnes-ai.com")!)
            }
        }
        .navigationTitle("AI 助手")
        .navigationBarTitleDisplayMode(.inline)
        .alert(testFailed ? "连接测试失败" : "连接成功", isPresented: $showTestAlert) {
            Button("好", role: .cancel) { }
        } message: {
            Text(testMessage ?? "")
        }
    }

    private func testConnection() {
        guard !apiKeyText.isEmpty else { return }
        isTesting = true
        testMessage = nil
        Task {
            do {
                _ = try await AgnesClient.shared.testConnection()
                testMessage = "已成功连接到 agnes-ai，模型可用。"
                testFailed = false
            } catch {
                testMessage = error.localizedDescription
                testFailed = true
            }
            isTesting = false
            showTestAlert = true
        }
    }
}
