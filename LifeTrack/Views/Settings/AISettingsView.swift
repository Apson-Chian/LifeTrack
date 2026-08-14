import SwiftUI

/// AI 管家设置：渠道、各自独立的 Keychain API Key、模型与连通性测试。
struct AISettingsView: View {
    @State private var isEnabled = AISettings.isEnabled
    @State private var provider = AISettings.selectedProvider
    @State private var apiKeyText = ""
    @State private var model = ""
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testFailed = false
    @State private var showTestAlert = false

    var body: some View {
        Form {
            Section {
                Toggle("启用 AI 管家", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, value in AISettings.setEnabled(value) }

                Picker("AI 渠道", selection: $provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: provider) { _, value in
                    AISettings.setSelectedProvider(value)
                    loadProviderValues()
                }

                SecureField("\(provider.displayName) API Key", text: $apiKeyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKeyText) { _, value in
                        AISettings.setApiKey(value, for: provider)
                    }

                Picker("模型", selection: $model) {
                    ForEach(provider.availableModels, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: model) { _, value in
                    guard !value.isEmpty else { return }
                    AISettings.setModel(value, for: provider)
                }

                Button { testConnection() } label: {
                    Label(isTesting ? "正在测试…" : "测试当前渠道", systemImage: "bolt.fill")
                }
                .disabled(isTesting || apiKeyText.isEmpty || !isEnabled)
            } header: {
                Text("模型渠道")
            } footer: {
                Text(providerFooter)
            }

            Section("它能做什么") {
                Label("结合运动、轨迹、停留、地点和课表连续对话", systemImage: "bubble.left.and.bubble.right")
                Label("根据家、学校与高频活动圈整理旅行", systemImage: "suitcase.rolling")
                Label("离开助手页面后继续生成回答", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
            }

            Section("照片隐私边界") {
                Label("可以知道", systemImage: "checkmark.shield")
                    .font(.headline)
                Text("本机聚合后的非人物类别、通用主题，以及某段已识别旅行包含多少张照片。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label("永远看不到", systemImage: "eye.slash")
                    .font(.headline)
                Text("原图、缩略图、人物与自拍、单张照片、资产标识符、路径、坐标和拍摄时间。照片 GPS 只在本机用于排除日常照片。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("当前连接") {
                LabeledContent("渠道", value: provider.displayName)
                LabeledContent("接口", value: provider == .agnes ? "apihub.agnes-ai.com" : "api.deepseek.com")
                LabeledContent("状态", value: AISettings.isConfigured ? "已配置" : "未配置")
                Link("打开 \(provider.displayName) 官网", destination: provider.website)
            }
        }
        .navigationTitle("AI 管家")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadProviderValues)
        .alert(testFailed ? "连接测试失败" : "连接成功", isPresented: $showTestAlert) {
            Button("好", role: .cancel) { }
        } message: {
            Text(testMessage ?? "")
        }
    }

    private var providerFooter: String {
        if provider == .agnes {
            return "Agnes 提供免费额度；实际频率限制以其服务为准。两个渠道的 API Key 分开保存在本机 Keychain。"
        }
        return "DeepSeek 使用官方 API，可能产生费用；默认使用 deepseek-v4-flash。API Key 只保存在本机 Keychain。"
    }

    private func loadProviderValues() {
        apiKeyText = AISettings.apiKey(for: provider) ?? ""
        model = AISettings.model(for: provider)
    }

    private func testConnection() {
        guard !apiKeyText.isEmpty else { return }
        let configuration = AIProviderConfiguration(provider: provider,
                                                    apiKey: apiKeyText,
                                                    model: model)
        isTesting = true
        Task {
            do {
                _ = try await AgnesClient.shared.testConnection(configuration: configuration)
                testMessage = "已成功连接到 \(provider.displayName)，当前模型可用。"
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
