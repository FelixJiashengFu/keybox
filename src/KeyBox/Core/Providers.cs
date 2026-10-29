namespace KeyBox.Core;

public enum TestKind
{
    None,
    /// <summary>GET {base}/models with "Authorization: Bearer".</summary>
    OpenAiModels,
    Anthropic,
    Gemini,
    OpenRouter,
    HuggingFace,
    GitHub,
    Stripe,
    Cloudflare,
}

public sealed record ProviderPreset(
    string Name,
    string Color,
    string BaseUrl,
    string EnvVar,
    string ConsoleUrl,
    TestKind Test,
    string[] EnvHints,
    string[] KeyPrefixes);

public static class Providers
{
    public const string Custom = "自定义";

    public static readonly ProviderPreset[] All =
    [
        new("OpenAI", "#10A37F", "https://api.openai.com/v1", "OPENAI_API_KEY", "https://platform.openai.com/api-keys", TestKind.OpenAiModels, ["OPENAI"], ["sk-proj-", "sk-svcacct-", "sk-admin-"]),
        new("Anthropic", "#D97757", "https://api.anthropic.com", "ANTHROPIC_API_KEY", "https://console.anthropic.com/settings/keys", TestKind.Anthropic, ["ANTHROPIC", "CLAUDE"], ["sk-ant-"]),
        new("DeepSeek", "#4D6BFE", "https://api.deepseek.com", "DEEPSEEK_API_KEY", "https://platform.deepseek.com/api_keys", TestKind.OpenAiModels, ["DEEPSEEK"], []),
        new("Google Gemini", "#1A73E8", "https://generativelanguage.googleapis.com/v1beta", "GEMINI_API_KEY", "https://aistudio.google.com/apikey", TestKind.Gemini, ["GEMINI", "GOOGLE_API", "GOOGLE_GENAI"], ["AIza"]),
        new("OpenRouter", "#6467F2", "https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", "https://openrouter.ai/settings/keys", TestKind.OpenRouter, ["OPENROUTER"], ["sk-or-"]),
        new("Kimi（月之暗面）", "#2F3A4A", "https://api.moonshot.cn/v1", "MOONSHOT_API_KEY", "https://platform.moonshot.cn/console/api-keys", TestKind.OpenAiModels, ["MOONSHOT", "KIMI"], []),
        new("通义千问（百炼）", "#615CED", "https://dashscope.aliyuncs.com/compatible-mode/v1", "DASHSCOPE_API_KEY", "https://bailian.console.aliyun.com/", TestKind.OpenAiModels, ["DASHSCOPE", "QWEN", "BAILIAN"], []),
        new("智谱 GLM", "#3859FF", "https://open.bigmodel.cn/api/paas/v4", "ZHIPUAI_API_KEY", "https://open.bigmodel.cn/usercenter/apikeys", TestKind.OpenAiModels, ["ZHIPU", "BIGMODEL", "GLM"], []),
        new("硅基流动", "#7C3AED", "https://api.siliconflow.cn/v1", "SILICONFLOW_API_KEY", "https://cloud.siliconflow.cn/account/ak", TestKind.OpenAiModels, ["SILICONFLOW"], []),
        new("xAI Grok", "#374151", "https://api.x.ai/v1", "XAI_API_KEY", "https://console.x.ai", TestKind.OpenAiModels, ["XAI", "GROK"], ["xai-"]),
        new("Mistral", "#FA520F", "https://api.mistral.ai/v1", "MISTRAL_API_KEY", "https://console.mistral.ai/api-keys", TestKind.OpenAiModels, ["MISTRAL"], []),
        new("Groq", "#F55036", "https://api.groq.com/openai/v1", "GROQ_API_KEY", "https://console.groq.com/keys", TestKind.OpenAiModels, ["GROQ"], ["gsk_"]),
        new("Hugging Face", "#D99A00", "https://huggingface.co", "HF_TOKEN", "https://huggingface.co/settings/tokens", TestKind.HuggingFace, ["HF_", "HUGGINGFACE", "HUGGING_FACE"], ["hf_"]),
        new("GitHub", "#57606A", "https://api.github.com", "GITHUB_TOKEN", "https://github.com/settings/tokens", TestKind.GitHub, ["GITHUB", "GH_"], ["github_pat_", "ghp_", "gho_", "ghu_", "ghs_"]),
        new("Stripe", "#635BFF", "https://api.stripe.com/v1", "STRIPE_SECRET_KEY", "https://dashboard.stripe.com/apikeys", TestKind.Stripe, ["STRIPE"], ["sk_live_", "sk_test_", "rk_live_", "rk_test_"]),
        new("Cloudflare", "#F38020", "https://api.cloudflare.com/client/v4", "CLOUDFLARE_API_TOKEN", "https://dash.cloudflare.com/profile/api-tokens", TestKind.Cloudflare, ["CLOUDFLARE", "CF_"], []),
    ];

    static readonly string[] Palette = ["#0F766E", "#B45309", "#7C3AED", "#BE185D", "#1D4ED8", "#15803D", "#9333EA", "#C2410C"];

    public static ProviderPreset? Find(string? name) =>
        string.IsNullOrWhiteSpace(name) ? null
        : All.FirstOrDefault(p => p.Name.Equals(name.Trim(), StringComparison.OrdinalIgnoreCase));

    public static string ColorFor(string provider, string fallbackSeed)
    {
        if (Find(provider) is { } p) return p.Color;
        var seed = provider.Trim().Length > 0 ? provider.Trim() : fallbackSeed;
        uint h = 2166136261;
        foreach (var c in seed.ToUpperInvariant()) h = (h ^ c) * 16777619;
        return Palette[h % (uint)Palette.Length];
    }

    /// <summary>Guess the provider from a key's well-known prefix (e.g. sk-ant-, ghp_, AIza).</summary>
    public static ProviderPreset? GuessFromKey(string key)
    {
        key = key.Trim();
        return All
            .SelectMany(p => p.KeyPrefixes.Select(prefix => (p, prefix)))
            .Where(x => key.StartsWith(x.prefix, StringComparison.Ordinal))
            .OrderByDescending(x => x.prefix.Length)
            .Select(x => x.p)
            .FirstOrDefault();
    }

    /// <summary>Guess the provider from an environment variable name such as DEEPSEEK_API_KEY.</summary>
    public static ProviderPreset? GuessFromEnvVar(string name)
    {
        var upper = name.Trim().ToUpperInvariant();
        return All.FirstOrDefault(p => p.EnvHints.Any(h => h.EndsWith('_') ? upper.StartsWith(h) : upper.Contains(h)));
    }
}
