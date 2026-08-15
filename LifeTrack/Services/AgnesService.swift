import Foundation

// MARK: - 隐私红线
// OpenAI Chat Completions 兼容的纯文本客户端。无论选择 Agnes 或 DeepSeek，
// 请求结构都不存在图片分支；照片只能由 PhotoAIPrivacyFilter 输出时间、脱敏地点、
// 轨迹关联和安全主题等纯文字元数据。

enum AIProvider: String, CaseIterable, Identifiable {
    case agnes
    case deepSeek = "deepseek"

    var id: String { rawValue }
    var displayName: String { self == .agnes ? "Agnes" : "DeepSeek" }
    var baseURL: String { self == .agnes ? "https://apihub.agnes-ai.com/v1" : "https://api.deepseek.com" }
    var defaultModel: String { self == .agnes ? "agnes-2.5-flash" : "deepseek-v4-flash" }
    var availableModels: [String] {
        self == .agnes
            ? ["agnes-2.5-flash", "agnes-2.0-flash"]
            : ["deepseek-v4-flash", "deepseek-v4-pro"]
    }
    var website: URL {
        URL(string: self == .agnes ? "https://agnes-ai.com" : "https://platform.deepseek.com")!
    }
}

struct AIProviderConfiguration: Sendable {
    let provider: AIProvider
    let apiKey: String
    let model: String
    var baseURL: String { provider.baseURL }
}

enum AISettings {
    private static let enabledKey = "ai.enabled"
    private static let providerKey = "ai.provider"

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            return UserDefaults.standard.bool(forKey: "agnes.enabled")
        }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ value: Bool) { UserDefaults.standard.set(value, forKey: enabledKey) }

    static var selectedProvider: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .agnes
    }

    static func setSelectedProvider(_ provider: AIProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: providerKey)
    }

    static func model(for provider: AIProvider) -> String {
        if let stored = UserDefaults.standard.string(forKey: "ai.\(provider.rawValue).model"), !stored.isEmpty {
            return stored
        }
        if provider == .agnes,
           let legacy = UserDefaults.standard.string(forKey: "agnes.model"), !legacy.isEmpty {
            return legacy
        }
        return provider.defaultModel
    }

    static func setModel(_ value: String, for provider: AIProvider) {
        UserDefaults.standard.set(value, forKey: "ai.\(provider.rawValue).model")
    }

    static func apiKey(for provider: AIProvider) -> String? {
        if let value = SecureValueStore.get("ai.\(provider.rawValue).apiKey"), !value.isEmpty { return value }
        if provider == .agnes,
           let legacy = SecureValueStore.get("agnes.apiKey"), !legacy.isEmpty { return legacy }
        return nil
    }

    static func setApiKey(_ value: String?, for provider: AIProvider) {
        let key = "ai.\(provider.rawValue).apiKey"
        if let value, !value.isEmpty {
            SecureValueStore.set(value, for: key)
        } else {
            SecureValueStore.remove(key)
        }
    }

    static var activeConfiguration: AIProviderConfiguration? {
        let provider = selectedProvider
        guard isEnabled, let apiKey = apiKey(for: provider) else { return nil }
        return AIProviderConfiguration(provider: provider,
                                       apiKey: apiKey,
                                       model: model(for: provider))
    }

    static var isConfigured: Bool { activeConfiguration != nil }
}

enum AgnesRole: String { case system, user, assistant, tool }

/// content 永远是字符串，没有 image/image_url 分支。
struct AgnesWireMessage {
    var role: String
    var content: String?
    var toolCalls: [AgnesWireToolCall]?
    var toolCallId: String?

    init(role: String, content: String? = nil, toolCalls: [AgnesWireToolCall]? = nil, toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    static func text(_ content: String, role: AgnesRole) -> AgnesWireMessage {
        AgnesWireMessage(role: role.rawValue, content: content)
    }
}

struct AgnesWireToolCall: Decodable {
    let id: String
    let type: String
    let function: Function
    let argumentsData: Data?

    init(id: String, type: String, function: Function, argumentsData: Data? = nil) {
        self.id = id
        self.type = type
        self.function = function
        self.argumentsData = argumentsData
    }

    struct Function: Decodable { let name: String; let arguments: String }
    enum CodingKeys: String, CodingKey { case id, type, function }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        function = try container.decode(Function.self, forKey: .function)
        argumentsData = function.arguments.data(using: .utf8)
    }

    func arguments() -> [String: Any] {
        guard let data = argumentsData else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

struct AgnesTool {
    let name: String
    let description: String
    let parameters: [String: Any]
}

enum AgnesOutcome { case content(String), toolCalls([AgnesWireToolCall]) }

enum AgnesError: LocalizedError {
    case notConfigured
    case emptyQuestion
    case invalidResponse
    case http(provider: String, status: Int, detail: String)
    case unexpectedToolCall

    var errorDescription: String? {
        switch self {
        case .notConfigured: "尚未配置所选 AI 渠道，请到“设置 → AI 管家”中填写 API Key。"
        case .emptyQuestion: "请输入想问的问题。"
        case .invalidResponse: "AI 返回的内容无法解析，请稍后重试。"
        case let .http(provider, status, detail):
            "\(provider) 请求失败（HTTP \(status)）：\(detail.prefix(200))"
        case .unexpectedToolCall: "模型在未提供工具时返回了工具调用。"
        }
    }
}

/// 保留原类型名以兼容现有代码；实际支持 Agnes 与 DeepSeek。
struct AgnesClient {
    static let shared = AgnesClient()
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func complete(messages: [AgnesWireMessage],
                  configuration: AIProviderConfiguration? = nil) async throws -> String {
        let outcome = try await completeWithTools(messages: messages,
                                                  tools: [],
                                                  configuration: configuration)
        switch outcome {
        case .content(let text): return text
        case .toolCalls: throw AgnesError.unexpectedToolCall
        }
    }

    func completeWithTools(messages: [AgnesWireMessage],
                           tools: [AgnesTool],
                           configuration supplied: AIProviderConfiguration? = nil) async throws -> AgnesOutcome {
        guard let configuration = supplied ?? AISettings.activeConfiguration else {
            throw AgnesError.notConfigured
        }

        var body: [String: Any] = [
            "model": configuration.model,
            "messages": messages.map(\.dictionary),
            "temperature": 0.7
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                ["type": "function",
                 "function": ["name": tool.name,
                              "description": tool.description,
                              "parameters": tool.parameters]]
            }
            body["tool_choice"] = "auto"
        }

        let base = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else { throw AgnesError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AgnesError.http(provider: configuration.provider.displayName,
                                  status: http.statusCode,
                                  detail: String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.parseOutcome(data: data)
    }

    func testConnection(configuration: AIProviderConfiguration? = nil) async throws -> String {
        try await complete(messages: [.text("用一句话中文回复：连接成功。", role: .user)],
                           configuration: configuration)
    }

    private static func parseOutcome(data: Data) throws -> AgnesOutcome {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AgnesError.invalidResponse
        }
        if let rawCalls = message["tool_calls"] as? [[String: Any]], !rawCalls.isEmpty {
            let calls = rawCalls.compactMap { raw -> AgnesWireToolCall? in
                guard let id = raw["id"] as? String,
                      let type = raw["type"] as? String,
                      let function = raw["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let arguments = function["arguments"] as? String else { return nil }
                return AgnesWireToolCall(id: id,
                                         type: type,
                                         function: .init(name: name, arguments: arguments),
                                         argumentsData: arguments.data(using: .utf8))
            }
            if !calls.isEmpty { return .toolCalls(calls) }
        }
        if let content = message["content"] as? String, !content.isEmpty { return .content(content) }
        throw AgnesError.invalidResponse
    }
}

extension AgnesWireMessage {
    var dictionary: [String: Any] {
        var result: [String: Any] = ["role": role, "content": content ?? NSNull()]
        if let toolCalls {
            result["tool_calls"] = toolCalls.map { call -> [String: Any] in
                ["id": call.id,
                 "type": call.type,
                 "function": ["name": call.function.name,
                              "arguments": call.function.arguments]]
            }
        }
        if let toolCallId { result["tool_call_id"] = toolCallId }
        return result
    }
}
