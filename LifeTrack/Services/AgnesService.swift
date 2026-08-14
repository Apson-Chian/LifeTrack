import Foundation

// MARK: - 隐私红线
//
// 本文件实现与 agnes-ai（OpenAI 兼容网关）的对话客户端。
// 设计上 **只发送文字（String content）**，不存在图片内容分支。
// Agent 工具层只允许照片解析结果经过 PhotoAIPrivacyFilter 后以聚合文本输出：
// 原图、缩略图、路径、资产标识符、坐标、拍摄时间和人物信息不会交给 Agnes。

enum AgnesSettings {
    private static let enabledKey = "agnes.enabled"
    private static let modelKey = "agnes.model"
    private static let apiKeyKey = "agnes.apiKey"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: enabledKey)
    }

    static var model: String {
        UserDefaults.standard.string(forKey: modelKey) ?? "agnes-2.5-flash"
    }

    static func setModel(_ value: String) {
        UserDefaults.standard.set(value, forKey: modelKey)
    }

    /// 固定为 Agnes 网关，防止本机普通设置被篡改后把数据发到其他服务。
    static let baseURL = "https://apihub.agnes-ai.com/v1"

    static var apiKey: String? {
        let key = SecureValueStore.get(apiKeyKey)
        return key?.isEmpty == false ? key : nil
    }

    static func setApiKey(_ value: String?) {
        if let value, !value.isEmpty {
            SecureValueStore.set(value, for: apiKeyKey)
        } else {
            SecureValueStore.remove(apiKeyKey)
        }
    }

    /// 是否已开启且配置了 Key。
    static var isConfigured: Bool {
        isEnabled && apiKey != nil
    }
}

enum AgnesRole: String {
    case system
    case user
    case assistant
    case tool
}

/// 发送给模型的单条消息。**content 永远是字符串**，没有图片内容分支。
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

    struct Function: Decodable {
        let name: String
        let arguments: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case function
    }

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

/// 工具定义（OpenAI 兼容 functions 格式）。
struct AgnesTool {
    let name: String
    let description: String
    /// JSON Schema 形式的 parameters（用 [String: Any] 描述，便于构造）。
    let parameters: [String: Any]
}

enum AgnesOutcome {
    case content(String)
    case toolCalls([AgnesWireToolCall])
}

enum AgnesError: LocalizedError {
    case notConfigured
    case emptyQuestion
    case invalidResponse
    case http(status: Int, detail: String)
    case unexpectedToolCall

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "尚未配置 Agnes API Key，请到“设置 → AI 助手”中填写。"
        case .emptyQuestion:
            "请输入想问的问题。"
        case .invalidResponse:
            "Agnes 返回的内容无法解析，请稍后重试。"
        case let .http(status, detail):
            "Agnes 请求失败（HTTP \(status)）：\(detail.prefix(200))"
        case .unexpectedToolCall:
            "模型在未提供工具时返回了工具调用。"
        }
    }
}

/// agnes-ai 客户端。仅支持文本对话与（可选的）工具调用，绝不包含图片。
struct AgnesClient {
    static let shared = AgnesClient()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func endpointURL() throws -> URL {
        let base = AgnesSettings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else {
            throw AgnesError.invalidResponse
        }
        return url
    }

    /// 简单文本对话（不使用工具）。
    func complete(messages: [AgnesWireMessage]) async throws -> String {
        let outcome = try await completeWithTools(messages: messages, tools: [])
        switch outcome {
        case .content(let text):
            return text
        case .toolCalls:
            throw AgnesError.unexpectedToolCall
        }
    }

    /// 带工具调用的对话。模型可能直接返回文字，也可能要求调用本地工具。
    func completeWithTools(messages: [AgnesWireMessage], tools: [AgnesTool]) async throws -> AgnesOutcome {
        guard let apiKey = AgnesSettings.apiKey else { throw AgnesError.notConfigured }

        var body: [String: Any] = [
            "model": AgnesSettings.model,
            "messages": messages.map { $0.dictionary },
            "temperature": 0.7
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters
                    ]
                ]
            }
            body["tool_choice"] = "auto"
        }

        let url = try endpointURL()
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AgnesError.http(status: http.statusCode, detail: detail)
        }

        return try Self.parseOutcome(data: data)
    }

    /// 轻量连通性测试。
    func testConnection() async throws -> String {
        try await complete(messages: [.text("用一句话中文回复：连接成功。", role: .user)])
    }

    private static func parseOutcome(data: Data) throws -> AgnesOutcome {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw AgnesError.invalidResponse
        }

        let content = message["content"] as? String
        let toolCallsRaw = message["tool_calls"] as? [[String: Any]]

        if let toolCallsRaw, !toolCallsRaw.isEmpty {
            let calls = toolCallsRaw.compactMap { raw -> AgnesWireToolCall? in
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

        if let content, !content.isEmpty {
            return .content(content)
        }

        throw AgnesError.invalidResponse
    }
}

extension AgnesWireMessage {
    /// 序列化为 OpenAI 兼容的请求体。结构上仅允许字符串 content。
    var dictionary: [String: Any] {
        var result: [String: Any] = ["role": role]
        if let content {
            result["content"] = content
        } else {
            result["content"] = NSNull()
        }
        if let toolCalls {
            result["tool_calls"] = toolCalls.map { call -> [String: Any] in
                [
                    "id": call.id,
                    "type": call.type,
                    "function": [
                        "name": call.function.name,
                        "arguments": call.function.arguments
                    ]
                ]
            }
        }
        if let toolCallId {
            result["tool_call_id"] = toolCallId
        }
        return result
    }
}
