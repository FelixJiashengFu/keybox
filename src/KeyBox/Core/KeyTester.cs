using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;

namespace KeyBox.Core;

public sealed record TestResult(bool Ok, string Message);

/// <summary>
/// Makes one read-only request to the provider (list models, whoami, balance) to see whether a key is accepted.
/// Only runs when the user clicks 测试.
/// </summary>
public static class KeyTester
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    static KeyTester()
    {
        Http.DefaultRequestHeaders.UserAgent.ParseAdd("KeyBox/1.0");
    }

    public static bool CanTest(ApiEntry e) => Kind(e) != TestKind.None && e.Key.Trim().Length > 0;

    static TestKind Kind(ApiEntry e) =>
        Providers.Find(e.Provider)?.Test ?? (e.BaseUrl.Trim().Length > 0 ? TestKind.OpenAiModels : TestKind.None);

    static string BaseUrl(ApiEntry e) =>
        (e.BaseUrl.Trim().Length > 0 ? e.BaseUrl.Trim() : Providers.Find(e.Provider)?.BaseUrl ?? "").TrimEnd('/');

    public static async Task<TestResult> TestAsync(ApiEntry entry, CancellationToken ct = default)
    {
        var key = entry.Key.Trim();
        var kind = Kind(entry);
        var baseUrl = BaseUrl(entry);
        if (kind == TestKind.None || baseUrl.Length == 0)
            return new(false, "这个服务商没有内置测试方式；填写 OpenAI 兼容的 Base URL 后可以测试。");

        var request = kind switch
        {
            TestKind.Anthropic => Get($"{baseUrl}/v1/models", ("x-api-key", key), ("anthropic-version", "2023-06-01")),
            TestKind.Gemini => Get($"{baseUrl}/models", ("x-goog-api-key", key)),
            TestKind.OpenRouter => Bearer($"{baseUrl}/key", key),
            TestKind.HuggingFace => Bearer($"{baseUrl}/api/whoami-v2", key),
            TestKind.GitHub => Bearer($"{baseUrl}/user", key),
            TestKind.Stripe => Bearer($"{baseUrl}/balance", key),
            TestKind.Cloudflare => Bearer($"{baseUrl}/user/tokens/verify", key),
            _ => Bearer($"{baseUrl}/models", key),
        };

        try
        {
            using var response = await Http.SendAsync(request, ct);
            var body = await response.Content.ReadAsStringAsync(ct);
            var code = (int)response.StatusCode;
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                return new(false, $"Key 被拒绝（HTTP {code}）：{Brief(body)}");
            if (response.StatusCode == HttpStatusCode.TooManyRequests)
                return new(true, "Key 有效，但当前被限流（HTTP 429）");
            if (!response.IsSuccessStatusCode)
                return new(false, $"HTTP {code}：{Brief(body)}");

            var detail = Describe(kind, body);
            if (Providers.Find(entry.Provider)?.Name == "DeepSeek")
                detail = Join(detail, await DeepSeekBalance(baseUrl, key, ct));
            return new(true, Join("Key 有效", detail));
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            return new(false, "请求超时（15 秒）");
        }
        catch (HttpRequestException ex)
        {
            return new(false, "网络错误：" + ex.Message);
        }
    }

    static HttpRequestMessage Get(string url, params (string Name, string Value)[] headers)
    {
        var req = new HttpRequestMessage(HttpMethod.Get, url);
        foreach (var (name, value) in headers) req.Headers.TryAddWithoutValidation(name, value);
        return req;
    }

    static HttpRequestMessage Bearer(string url, string key)
    {
        var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        return req;
    }

    static string Describe(TestKind kind, string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            switch (kind)
            {
                case TestKind.OpenAiModels or TestKind.Anthropic when root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Array:
                    return $"可用模型 {data.GetArrayLength()} 个";
                case TestKind.Gemini when root.TryGetProperty("models", out var models) && models.ValueKind == JsonValueKind.Array:
                    return $"可用模型 {models.GetArrayLength()} 个";
                case TestKind.HuggingFace or TestKind.GitHub:
                    foreach (var field in new[] { "name", "login" })
                        if (root.TryGetProperty(field, out var who) && who.ValueKind == JsonValueKind.String)
                            return "账号 " + who.GetString();
                    break;
                case TestKind.OpenRouter when root.TryGetProperty("data", out var info):
                    if (info.TryGetProperty("usage", out var usage) && usage.ValueKind == JsonValueKind.Number)
                        return $"已用 ${usage.GetDouble():0.##}"
                            + (info.TryGetProperty("limit", out var limit) && limit.ValueKind == JsonValueKind.Number ? $" / 上限 ${limit.GetDouble():0.##}" : "");
                    break;
                case TestKind.Stripe when root.TryGetProperty("livemode", out var live):
                    return live.GetBoolean() ? "正式环境（live）" : "测试环境（test）";
                case TestKind.Cloudflare when root.TryGetProperty("result", out var result) && result.TryGetProperty("status", out var status):
                    return "状态 " + status.GetString();
            }
        }
        catch (JsonException) { }
        return "";
    }

    static async Task<string> DeepSeekBalance(string baseUrl, string key, CancellationToken ct)
    {
        try
        {
            using var response = await Http.SendAsync(Bearer($"{baseUrl}/user/balance", key), ct);
            if (!response.IsSuccessStatusCode) return "";
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
            if (!doc.RootElement.TryGetProperty("balance_infos", out var infos)) return "";
            var parts = infos.EnumerateArray()
                .Select(b => (b.TryGetProperty("currency", out var c) ? c.GetString() : "") switch
                {
                    "CNY" => "¥",
                    "USD" => "$",
                    var other => other + " ",
                } + (b.TryGetProperty("total_balance", out var t) ? t.GetString() : "?"));
            return "余额 " + string.Join(" / ", parts);
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or TaskCanceledException or InvalidOperationException)
        {
            return "";
        }
    }

    static string Join(string a, string b) => b.Length == 0 ? a : a.Length == 0 ? b : a + " · " + b;

    static string Brief(string body)
    {
        body = body.ReplaceLineEndings(" ").Trim();
        try
        {
            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            if (root.TryGetProperty("error", out var err))
            {
                if (err.ValueKind == JsonValueKind.String) body = err.GetString() ?? body;
                else if (err.TryGetProperty("message", out var msg)) body = msg.GetString() ?? body;
            }
            else if (root.TryGetProperty("message", out var msg2) && msg2.ValueKind == JsonValueKind.String) body = msg2.GetString() ?? body;
        }
        catch (JsonException) { }
        return body.Length > 160 ? body[..160] + "…" : body.Length == 0 ? "（无内容）" : body;
    }
}
