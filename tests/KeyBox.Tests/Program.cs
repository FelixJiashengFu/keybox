// Plain console checks for KeyBox's core (no test framework needed): dotnet run --project tests/KeyBox.Tests
using System.Collections;
using System.IO;
using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using KeyBox.Core;

if (args is ["--write-fixture", var fixtureDir])
{
    Fixtures.WriteWindows(fixtureDir);
    Console.WriteLine("wrote windows-vault.json and windows-expect.json to " + Path.GetFullPath(fixtureDir));
    return 0;
}

var failures = new List<string>();
int passed = 0;

void Check(string name, bool ok)
{
    if (ok) passed++;
    else failures.Add(name);
    Console.WriteLine((ok ? "  ok   " : "  FAIL ") + name);
}

void Throws<T>(string name, Action action) where T : Exception
{
    try { action(); Check(name + "（应抛出 " + typeof(T).Name + "）", false); }
    catch (T) { Check(name, true); }
    catch (Exception ex) { Check($"{name}（抛出了 {ex.GetType().Name}: {ex.Message}）", false); }
}

var tmp = Path.Combine(Path.GetTempPath(), "keybox-tests-" + Guid.NewGuid().ToString("N")[..8]);
Directory.CreateDirectory(tmp);
var paths = new DataPaths(tmp);

try
{
    Console.WriteLine("Vault");
    var v = Vault.Create(paths.Vault, "correct horse 电池", iterations: 100_000);
    v.Data.Entries.Add(new ApiEntry { Name = "DeepSeek 主账号", Provider = "DeepSeek", Key = "sk-test-0123456789abcdef", EnvVar = "DEEPSEEK_API_KEY" });
    v.Save();
    var raw = File.ReadAllText(paths.Vault);
    Check("file does not contain the key in plaintext", !raw.Contains("0123456789abcdef") && !raw.Contains("DeepSeek 主账号"));
    Check("previous version kept as .bak", File.Exists(paths.Vault + ".bak"));

    var reopened = Vault.Open(paths.Vault, "correct horse 电池");
    Check("round-trips entries", reopened.Data.Entries.Count == 1 && reopened.Data.Entries[0].Key == "sk-test-0123456789abcdef");
    Check("round-trips Chinese text", reopened.Data.Entries[0].Name == "DeepSeek 主账号");
    Throws<WrongPasswordException>("wrong password is rejected", () => Vault.Open(paths.Vault, "correct horse 电池!"));

    // Same password typed as decomposed Unicode (e.g. é as e + U+0301) still unlocks.
    var v2Path = Path.Combine(tmp, "nfc.json");
    Vault.Create(v2Path, "caf\u00e9-password", iterations: 100_000).Close();
    Check("password is Unicode-normalised", Vault.Open(v2Path, "cafe\u0301-password").IsOpen);

    // Tampering with the ciphertext or with the header both fail authentication.
    var node = JsonNode.Parse(raw)!;
    var blob = Convert.FromBase64String((string)node["data"]!);
    blob[3] ^= 0x01;
    node["data"] = Convert.ToBase64String(blob);
    var tampered = Path.Combine(tmp, "tampered.json");
    File.WriteAllText(tampered, node.ToJsonString());
    Throws<WrongPasswordException>("modified ciphertext is detected", () => Vault.Open(tampered, "correct horse 电池"));

    node = JsonNode.Parse(raw)!;
    node["kdf"]!["iterations"] = 100_001;
    File.WriteAllText(tampered, node.ToJsonString());
    Throws<WrongPasswordException>("modified header is detected", () => Vault.Open(tampered, "correct horse 电池"));

    node = JsonNode.Parse(raw)!;
    node["kdf"]!["iterations"] = 10;
    File.WriteAllText(tampered, node.ToJsonString());
    Throws<InvalidDataException>("absurdly low iteration count is refused", () => Vault.Open(tampered, "correct horse 电池"));

    Check("CheckPassword accepts the right password", reopened.CheckPassword("correct horse 电池"));
    Check("CheckPassword rejects a wrong one", !reopened.CheckPassword("nope nope"));

    Console.WriteLine("Device unlock (DPAPI)");
    DeviceUnlock.Enable(paths, reopened);
    var quick = DeviceUnlock.TryOpen(paths);
    Check("quick unlock opens the vault", quick is not null && quick.Data.Entries.Count == 1);
    Check("device.key does not hold the raw key", !File.ReadAllText(paths.DeviceKey).Contains(Convert.ToBase64String(reopened.ExportKey())));

    reopened.ChangePassword("a brand new secret");
    Check("new password works after change", Vault.Open(paths.Vault, "a brand new secret").Data.Entries.Count == 1);
    Throws<WrongPasswordException>("old password stops working", () => Vault.Open(paths.Vault, "correct horse 电池"));
    Check("stale device key is refused and removed", DeviceUnlock.TryOpen(paths) is null && !DeviceUnlock.IsEnabled(paths));
    Check("new vault uses full iteration count", JsonNode.Parse(File.ReadAllText(paths.Vault))!["kdf"]!["iterations"]!.GetValue<int>() == Vault.DefaultIterations);
    Throws<IOException>("Create refuses to overwrite", () => Vault.Create(paths.Vault, "whatever123"));

    reopened.Close();
    Check("Close forgets entries and key", !reopened.IsOpen && reopened.Data.Entries.Count == 0);
    Throws<InvalidOperationException>("Save after Close is refused", reopened.Save);

    Console.WriteLine("Providers");
    Check("sk-ant- → Anthropic", Providers.GuessFromKey("sk-ant-api03-xyz")?.Name == "Anthropic");
    Check("sk-or- → OpenRouter", Providers.GuessFromKey("sk-or-v1-abc")?.Name == "OpenRouter");
    Check("sk-proj- → OpenAI", Providers.GuessFromKey("sk-proj-abc")?.Name == "OpenAI");
    Check("github_pat_ → GitHub", Providers.GuessFromKey("github_pat_11ABC")?.Name == "GitHub");
    Check("AIza → Gemini", Providers.GuessFromKey("AIzaSyA-1234")?.Name == "Google Gemini");
    Check("bare sk- is not guessed", Providers.GuessFromKey("sk-0123456789") is null);
    Check("DEEPSEEK_API_KEY → DeepSeek", Providers.GuessFromEnvVar("DEEPSEEK_API_KEY")?.Name == "DeepSeek");
    Check("HF_TOKEN → Hugging Face", Providers.GuessFromEnvVar("HF_TOKEN")?.Name == "Hugging Face");
    Check("GH_TOKEN → GitHub", Providers.GuessFromEnvVar("GH_TOKEN")?.Name == "GitHub");
    Check("MY_HF_TOKEN is not Hugging Face", Providers.GuessFromEnvVar("MY_HF_TOKEN")?.Name != "Hugging Face");
    Check("preset colour is stable", Providers.ColorFor("DeepSeek", "x") == "#4D6BFE");
    Check("custom colour is deterministic", Providers.ColorFor("Foo Cloud", "x") == Providers.ColorFor("foo cloud", "y"));

    Console.WriteLine("Environment scan");
    var fakeEnv = new Hashtable
    {
        ["DEEPSEEK_API_KEY"] = "sk-aaaaaaaaaaaaaaaa",
        ["Path"] = @"C:\Windows",
        ["GITHUB_TOKEN"] = "ghp_bbbbbbbbbbbbbbbbbbbb",
        ["SOME_SECRET"] = "short",
        ["OneDrive"] = @"C:\Users\x\OneDrive",
        ["STRIPE_SECRET_KEY"] = "sk_test_cccccccccccc",
    };
    var stored = new[] { new ApiEntry { Key = "ghp_bbbbbbbbbbbbbbbbbbbb" } };
    var found = EnvScanner.Candidates(fakeEnv, stored);
    Check("finds key-like variables only", found.Select(c => c.Name).OrderBy(n => n).SequenceEqual(["DEEPSEEK_API_KEY", "GITHUB_TOKEN", "STRIPE_SECRET_KEY"]));
    Check("marks already-stored keys", found.Single(c => c.Name == "GITHUB_TOKEN").AlreadyStored);
    Check("guesses provider", found.Single(c => c.Name == "STRIPE_SECRET_KEY").Guess?.Name == "Stripe");
    var imported = EnvScanner.ToEntry(found.Single(c => c.Name == "DEEPSEEK_API_KEY"));
    Check("import fills preset fields", imported.Provider == "DeepSeek" && imported.BaseUrl == "https://api.deepseek.com" && imported.EnvVar == "DEEPSEEK_API_KEY");

    Console.WriteLine("Snippets and masking");
    Check("PowerShell quoting", Snippets.PowerShell("K", "a'b") == "$env:K = 'a''b'");
    Check("Bash quoting", Snippets.Bash("K", "a'b") == "export K='a'\\''b'");
    Check(".env plain", Snippets.DotEnv("K", "abc123") == "K=abc123");
    Check(".env quoted", Snippets.DotEnv("K", "a b\"c") == "K=\"a b\\\"c\"");
    Check("valid env names", Snippets.IsValidName("OPENAI_API_KEY") && Snippets.IsValidName("_X1"));
    Check("invalid env names", !Snippets.IsValidName("1ABC") && !Snippets.IsValidName("A-B") && !Snippets.IsValidName(""));
    Check("mask keeps 4+4", ApiEntry.Mask("sk-0123456789abcdefWXYZ") == "sk-0" + new string('•', 12) + "WXYZ");
    Check("short secrets fully masked", ApiEntry.Mask("short123") == new string('•', 10));
    var search = new ApiEntry { Name = "工作账号", Provider = "OpenAI", EnvVar = "OPENAI_API_KEY", Notes = "MolAstria 用" };
    Check("search matches all terms", search.Matches("openai molastria") && !search.Matches("openai deepseek"));

    Console.WriteLine("Key tester (local mock server)");
    using var server = new MockServer();
    var ok = await KeyTester.TestAsync(new ApiEntry { Provider = "我的中转", BaseUrl = server.Url + "v1", Key = "good-key" });
    Check("OpenAI-compatible success counts models: " + ok.Message, ok.Ok && ok.Message.Contains("可用模型 3 个"));
    var bad = await KeyTester.TestAsync(new ApiEntry { Provider = "我的中转", BaseUrl = server.Url + "v1", Key = "bad-key" });
    Check("401 is reported as rejected: " + bad.Message, !bad.Ok && bad.Message.Contains("401") && bad.Message.Contains("invalid key"));
    var ds = await KeyTester.TestAsync(new ApiEntry { Provider = "DeepSeek", BaseUrl = server.Url.TrimEnd('/'), Key = "good-key" });
    Check("DeepSeek adds balance: " + ds.Message, ds.Ok && ds.Message.Contains("余额 ¥110.00"));
    var claude = await KeyTester.TestAsync(new ApiEntry { Provider = "Anthropic", BaseUrl = server.Url.TrimEnd('/'), Key = "good-key" });
    Check("Anthropic uses x-api-key: " + claude.Message, claude.Ok && server.LastHeaders?["x-api-key"] == "good-key" && server.LastHeaders?["anthropic-version"] is not null);
    Check("no base URL, unknown provider → not testable", !KeyTester.CanTest(new ApiEntry { Provider = "某云", Key = "k" }));

    Console.WriteLine("Cross-platform vault files (tests/fixtures)");
    var win = Fixtures.Check("windows-vault.json", "windows-expect.json");
    Check("Windows fixture still opens: " + string.Join("; ", win ?? ["missing"]), win is { Count: 0 });
    var mac = Fixtures.Check("mac-vault.json", "mac-expect.json");
    if (mac is null) Console.WriteLine("  --   mac-vault.json not there yet (comes from the Mac CI run)");
    else Check("vault written by the Mac app opens here: " + string.Join("; ", mac), mac.Count == 0);
}
finally
{
    Directory.Delete(tmp, recursive: true);
}

Console.WriteLine();
Console.WriteLine(failures.Count == 0 ? $"全部通过：{passed} 项" : $"{failures.Count} 项失败：\n  " + string.Join("\n  ", failures));
return failures.Count == 0 ? 0 : 1;

/// <summary>Answers like an OpenAI-compatible API: "good-key" is accepted, anything else gets 401.</summary>
sealed class MockServer : IDisposable
{
    readonly HttpListener listener = new();
    public string Url { get; }
    public System.Collections.Specialized.NameValueCollection? LastHeaders { get; private set; }

    public MockServer()
    {
        var port = Random.Shared.Next(20000, 60000);
        Url = $"http://localhost:{port}/";
        listener.Prefixes.Add(Url);
        listener.Start();
        _ = Task.Run(Loop);
    }

    async Task Loop()
    {
        while (listener.IsListening)
        {
            HttpListenerContext ctx;
            try { ctx = await listener.GetContextAsync(); } catch { return; }
            LastHeaders = ctx.Request.Headers;
            var auth = ctx.Request.Headers["Authorization"] ?? "";
            var good = auth == "Bearer good-key" || ctx.Request.Headers["x-api-key"] == "good-key";
            var path = ctx.Request.Url!.AbsolutePath;
            string body;
            if (!good) { ctx.Response.StatusCode = 401; body = """{"error":{"message":"invalid key"}}"""; }
            else if (path.EndsWith("/user/balance")) body = """{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00"}]}""";
            else body = """{"object":"list","data":[{"id":"a"},{"id":"b"},{"id":"c"}]}""";
            var bytes = Encoding.UTF8.GetBytes(body);
            ctx.Response.ContentType = "application/json";
            await ctx.Response.OutputStream.WriteAsync(bytes);
            ctx.Response.Close();
        }
    }

    public void Dispose() => listener.Close();
}
