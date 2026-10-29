import Foundation

public enum TestKind: Sendable {
    case none
    /// GET {base}/models with "Authorization: Bearer".
    case openAIModels
    case anthropic, gemini, openRouter, huggingFace, gitHub, stripe, cloudflare
}

public struct ProviderPreset: Hashable, Sendable {
    public let name: String
    public let color: String
    public let baseUrl: String
    public let envVar: String
    public let consoleUrl: String
    public let test: TestKind
    let envHints: [String]
    let keyPrefixes: [String]
}

/// The same presets as the Windows version (src/KeyBox/Core/Providers.cs).
public enum Providers {
    public static let all: [ProviderPreset] = [
        .init(name: "OpenAI", color: "#10A37F", baseUrl: "https://api.openai.com/v1", envVar: "OPENAI_API_KEY", consoleUrl: "https://platform.openai.com/api-keys", test: .openAIModels, envHints: ["OPENAI"], keyPrefixes: ["sk-proj-", "sk-svcacct-", "sk-admin-"]),
        .init(name: "Anthropic", color: "#D97757", baseUrl: "https://api.anthropic.com", envVar: "ANTHROPIC_API_KEY", consoleUrl: "https://console.anthropic.com/settings/keys", test: .anthropic, envHints: ["ANTHROPIC", "CLAUDE"], keyPrefixes: ["sk-ant-"]),
        .init(name: "DeepSeek", color: "#4D6BFE", baseUrl: "https://api.deepseek.com", envVar: "DEEPSEEK_API_KEY", consoleUrl: "https://platform.deepseek.com/api_keys", test: .openAIModels, envHints: ["DEEPSEEK"], keyPrefixes: []),
        .init(name: "Google Gemini", color: "#1A73E8", baseUrl: "https://generativelanguage.googleapis.com/v1beta", envVar: "GEMINI_API_KEY", consoleUrl: "https://aistudio.google.com/apikey", test: .gemini, envHints: ["GEMINI", "GOOGLE_API", "GOOGLE_GENAI"], keyPrefixes: ["AIza"]),
        .init(name: "OpenRouter", color: "#6467F2", baseUrl: "https://openrouter.ai/api/v1", envVar: "OPENROUTER_API_KEY", consoleUrl: "https://openrouter.ai/settings/keys", test: .openRouter, envHints: ["OPENROUTER"], keyPrefixes: ["sk-or-"]),
        .init(name: "Kimi（月之暗面）", color: "#2F3A4A", baseUrl: "https://api.moonshot.cn/v1", envVar: "MOONSHOT_API_KEY", consoleUrl: "https://platform.moonshot.cn/console/api-keys", test: .openAIModels, envHints: ["MOONSHOT", "KIMI"], keyPrefixes: []),
        .init(name: "通义千问（百炼）", color: "#615CED", baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1", envVar: "DASHSCOPE_API_KEY", consoleUrl: "https://bailian.console.aliyun.com/", test: .openAIModels, envHints: ["DASHSCOPE", "QWEN", "BAILIAN"], keyPrefixes: []),
        .init(name: "智谱 GLM", color: "#3859FF", baseUrl: "https://open.bigmodel.cn/api/paas/v4", envVar: "ZHIPUAI_API_KEY", consoleUrl: "https://open.bigmodel.cn/usercenter/apikeys", test: .openAIModels, envHints: ["ZHIPU", "BIGMODEL", "GLM"], keyPrefixes: []),
        .init(name: "硅基流动", color: "#7C3AED", baseUrl: "https://api.siliconflow.cn/v1", envVar: "SILICONFLOW_API_KEY", consoleUrl: "https://cloud.siliconflow.cn/account/ak", test: .openAIModels, envHints: ["SILICONFLOW"], keyPrefixes: []),
        .init(name: "xAI Grok", color: "#374151", baseUrl: "https://api.x.ai/v1", envVar: "XAI_API_KEY", consoleUrl: "https://console.x.ai", test: .openAIModels, envHints: ["XAI", "GROK"], keyPrefixes: ["xai-"]),
        .init(name: "Mistral", color: "#FA520F", baseUrl: "https://api.mistral.ai/v1", envVar: "MISTRAL_API_KEY", consoleUrl: "https://console.mistral.ai/api-keys", test: .openAIModels, envHints: ["MISTRAL"], keyPrefixes: []),
        .init(name: "Groq", color: "#F55036", baseUrl: "https://api.groq.com/openai/v1", envVar: "GROQ_API_KEY", consoleUrl: "https://console.groq.com/keys", test: .openAIModels, envHints: ["GROQ"], keyPrefixes: ["gsk_"]),
        .init(name: "Hugging Face", color: "#D99A00", baseUrl: "https://huggingface.co", envVar: "HF_TOKEN", consoleUrl: "https://huggingface.co/settings/tokens", test: .huggingFace, envHints: ["HF_", "HUGGINGFACE", "HUGGING_FACE"], keyPrefixes: ["hf_"]),
        .init(name: "GitHub", color: "#57606A", baseUrl: "https://api.github.com", envVar: "GITHUB_TOKEN", consoleUrl: "https://github.com/settings/tokens", test: .gitHub, envHints: ["GITHUB", "GH_"], keyPrefixes: ["github_pat_", "ghp_", "gho_", "ghu_", "ghs_"]),
        .init(name: "Stripe", color: "#635BFF", baseUrl: "https://api.stripe.com/v1", envVar: "STRIPE_SECRET_KEY", consoleUrl: "https://dashboard.stripe.com/apikeys", test: .stripe, envHints: ["STRIPE"], keyPrefixes: ["sk_live_", "sk_test_", "rk_live_", "rk_test_"]),
        .init(name: "Cloudflare", color: "#F38020", baseUrl: "https://api.cloudflare.com/client/v4", envVar: "CLOUDFLARE_API_TOKEN", consoleUrl: "https://dash.cloudflare.com/profile/api-tokens", test: .cloudflare, envHints: ["CLOUDFLARE", "CF_"], keyPrefixes: []),
    ]

    static let palette = ["#0F766E", "#B45309", "#7C3AED", "#BE185D", "#1D4ED8", "#15803D", "#9333EA", "#C2410C"]

    public static func find(_ name: String?) -> ProviderPreset? {
        guard let n = name?.trimmed, !n.isEmpty else { return nil }
        return all.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }

    /// FNV-1a over the UTF-16 code units of the upper-cased name — identical to the Windows version,
    /// so a custom provider gets the same avatar colour on both.
    public static func color(for provider: String, fallbackSeed: String) -> String {
        if let p = find(provider) { return p.color }
        let seed = provider.trimmed.isEmpty ? fallbackSeed : provider.trimmed
        var h: UInt32 = 2_166_136_261
        for unit in seed.uppercased().utf16 { h = (h ^ UInt32(unit)) &* 16_777_619 }
        return palette[Int(h % UInt32(palette.count))]
    }

    /// Guess the provider from a key's well-known prefix (sk-ant-, ghp_, AIza…).
    public static func guess(fromKey key: String) -> ProviderPreset? {
        let k = key.trimmed
        return all
            .flatMap { p in p.keyPrefixes.map { (p, $0) } }
            .filter { k.hasPrefix($0.1) }
            .max { $0.1.count < $1.1.count }?.0
    }

    /// Guess the provider from an environment variable name such as DEEPSEEK_API_KEY.
    public static func guess(fromEnvVar name: String) -> ProviderPreset? {
        let upper = name.trimmed.uppercased()
        return all.first { p in p.envHints.contains { h in h.hasSuffix("_") ? upper.hasPrefix(h) : upper.contains(h) } }
    }
}
