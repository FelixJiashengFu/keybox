import Foundation

public struct TestResult: Equatable, Sendable {
    public let ok: Bool
    public let message: String
}

/// Makes one read-only request to the provider (list models, whoami, balance) to see whether a key is
/// accepted. Only runs when the user clicks 测试. Mirrors src/KeyBox/Core/KeyTester.cs.
public enum KeyTester {
    public static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    public static func canTest(_ e: ApiEntry) -> Bool { kind(e) != .none && !e.key.trimmed.isEmpty }

    static func kind(_ e: ApiEntry) -> TestKind {
        if let p = Providers.find(e.provider) { return p.test }
        return e.baseUrl.trimmed.isEmpty ? .none : .openAIModels
    }

    static func baseUrl(_ e: ApiEntry) -> String {
        var s = e.baseUrl.trimmed.isEmpty ? (Providers.find(e.provider)?.baseUrl ?? "") : e.baseUrl.trimmed
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public static func test(_ entry: ApiEntry, session: URLSession = sharedSession) async -> TestResult {
        let key = entry.key.trimmed
        let kind = kind(entry)
        let base = baseUrl(entry)
        guard kind != .none, !base.isEmpty else {
            return TestResult(ok: false, message: "这个服务商没有内置测试方式；填写 OpenAI 兼容的 Base URL 后可以测试。")
        }

        let request: URLRequest?
        switch kind {
        case .anthropic: request = get("\(base)/v1/models", ["x-api-key": key, "anthropic-version": "2023-06-01"])
        case .gemini: request = get("\(base)/models", ["x-goog-api-key": key])
        case .openRouter: request = bearer("\(base)/key", key)
        case .huggingFace: request = bearer("\(base)/api/whoami-v2", key)
        case .gitHub: request = bearer("\(base)/user", key)
        case .stripe: request = bearer("\(base)/balance", key)
        case .cloudflare: request = bearer("\(base)/user/tokens/verify", key)
        case .openAIModels, .none: request = bearer("\(base)/models", key)
        }
        guard let request else { return TestResult(ok: false, message: "Base URL 不是有效的网址") }

        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data, as: UTF8.self)
            if code == 401 || code == 403 { return TestResult(ok: false, message: "Key 被拒绝（HTTP \(code)）：\(brief(body))") }
            if code == 429 { return TestResult(ok: true, message: "Key 有效，但当前被限流（HTTP 429）") }
            guard (200..<300).contains(code) else { return TestResult(ok: false, message: "HTTP \(code)：\(brief(body))") }

            var detail = describe(kind, data)
            if Providers.find(entry.provider)?.name == "DeepSeek" {
                detail = join(detail, await deepSeekBalance(base, key, session))
            }
            return TestResult(ok: true, message: join("Key 有效", detail))
        } catch let error as URLError where error.code == .timedOut {
            return TestResult(ok: false, message: "请求超时（15 秒）")
        } catch {
            return TestResult(ok: false, message: "网络错误：" + error.localizedDescription)
        }
    }

    static func get(_ url: String, _ headers: [String: String]) -> URLRequest? {
        guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http" else { return nil }
        var r = URLRequest(url: u)
        r.setValue("KeyBox/1.0", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    static func bearer(_ url: String, _ key: String) -> URLRequest? { get(url, ["Authorization": "Bearer " + key]) }

    static func json(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

    static func describe(_ kind: TestKind, _ data: Data) -> String {
        guard let root = json(data) else { return "" }
        switch kind {
        case .openAIModels, .anthropic:
            if let list = root["data"] as? [Any] { return "可用模型 \(list.count) 个" }
        case .gemini:
            if let list = root["models"] as? [Any] { return "可用模型 \(list.count) 个" }
        case .huggingFace, .gitHub:
            for field in ["name", "login"] { if let who = root[field] as? String { return "账号 " + who } }
        case .openRouter:
            if let info = root["data"] as? [String: Any], let usage = info["usage"] as? Double {
                var s = "已用 $" + money(usage)
                if let limit = info["limit"] as? Double { s += " / 上限 $" + money(limit) }
                return s
            }
        case .stripe:
            if let live = root["livemode"] as? Bool { return live ? "正式环境（live）" : "测试环境（test）" }
        case .cloudflare:
            if let result = root["result"] as? [String: Any], let status = result["status"] as? String { return "状态 " + status }
        case .none:
            break
        }
        return ""
    }

    static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.decimalSeparator = "."
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    static func deepSeekBalance(_ base: String, _ key: String, _ session: URLSession) async -> String {
        guard let request = bearer("\(base)/user/balance", key),
              let result = try? await session.data(for: request),
              let code = (result.1 as? HTTPURLResponse)?.statusCode, (200..<300).contains(code),
              let infos = json(result.0)?["balance_infos"] as? [[String: Any]]
        else { return "" }
        let parts = infos.map { b -> String in
            let currency = b["currency"] as? String ?? ""
            let symbol = currency == "CNY" ? "¥" : currency == "USD" ? "$" : currency + " "
            return symbol + (b["total_balance"] as? String ?? "?")
        }
        return "余额 " + parts.joined(separator: " / ")
    }

    static func join(_ a: String, _ b: String) -> String { b.isEmpty ? a : a.isEmpty ? b : a + " · " + b }

    static func brief(_ body: String) -> String {
        var text = body.replacingOccurrences(of: "\n", with: " ").trimmed
        if let root = json(Data(text.utf8)) {
            if let err = root["error"] as? String { text = err }
            else if let err = root["error"] as? [String: Any], let msg = err["message"] as? String { text = msg }
            else if let msg = root["message"] as? String { text = msg }
        }
        if text.isEmpty { return "（无内容）" }
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}
