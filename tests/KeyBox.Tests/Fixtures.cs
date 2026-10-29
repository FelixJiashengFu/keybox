using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using KeyBox.Core;

/// <summary>
/// Vault files in tests/fixtures that prove the Windows and Mac versions read each other's vault.json:
/// windows-vault.json is written here and checked by the Mac tests; mac-vault.json comes from the Mac
/// CI run and is checked here. Each *-expect.json lists what the other side must find.
/// </summary>
static class Fixtures
{
    public const string Password = "fixture-密码-123";

    public static string Dir => Path.GetFullPath(Path.Combine(Path.GetDirectoryName(ThisFile())!, "..", "fixtures"));
    static string ThisFile([CallerFilePath] string path = "") => path;

    public sealed record ExpectEntry(
        string Id, string Name, string Provider, string Key, string BaseUrl, string EnvVar, string ConsoleUrl, string Notes,
        string Color, string Masked, string Bash, string DotEnv, string Created, string? LastCopied);

    public sealed record Expect(string Password, List<ExpectEntry> Entries);

    public static void WriteWindows(string dir)
    {
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "windows-vault.json");
        if (File.Exists(path)) File.Delete(path);
        var vault = Vault.Create(path, Password);
        vault.Data.Entries.Add(new ApiEntry
        {
            Name = "DeepSeek 主账号",
            Provider = "DeepSeek",
            Key = "sk-fixture-0123456789abcdef",
            BaseUrl = "https://api.deepseek.com",
            EnvVar = "DEEPSEEK_API_KEY",
            ConsoleUrl = "https://platform.deepseek.com/api_keys",
            Notes = "第一行\n第二行 \"双引号\" 'single' \\ 反斜杠",
            LastCopied = new DateTime(2026, 10, 29, 9, 30, 15, 123, DateTimeKind.Local),
        });
        vault.Data.Entries.Add(new ApiEntry
        {
            Name = "中转站",
            Provider = "我的中转",
            Key = "relay-key-with'quote#1",
            BaseUrl = "https://relay.example.com/v1",
            EnvVar = "RELAY_API_KEY",
        });
        vault.Save();
        File.Delete(path + ".bak");
        File.WriteAllText(Path.Combine(dir, "windows-expect.json"), JsonSerializer.Serialize(Describe(vault.Data.Entries), Vault.Json));
    }

    static Expect Describe(IEnumerable<ApiEntry> entries) => new(Password, entries.Select(e => new ExpectEntry(
        e.Id, e.Name, e.Provider, e.Key, e.BaseUrl, e.EnvVar, e.ConsoleUrl, e.Notes,
        e.Color, e.MaskedKey, Snippets.Bash(e.EnvVar, e.Key), Snippets.DotEnv(e.EnvVar, e.Key),
        e.Created.ToUniversalTime().ToString("o"), e.LastCopied?.ToUniversalTime().ToString("o"))).ToList());

    /// <summary>Opens a fixture vault and compares it with its expect file. Null when the fixture is absent.</summary>
    public static List<string>? Check(string vaultName, string expectName)
    {
        var vaultPath = Path.Combine(Dir, vaultName);
        var expectPath = Path.Combine(Dir, expectName);
        if (!File.Exists(vaultPath) || !File.Exists(expectPath)) return null;
        var expect = JsonSerializer.Deserialize<Expect>(File.ReadAllText(expectPath), Vault.Json)!;
        var problems = new List<string>();
        var vault = Vault.Open(vaultPath, expect.Password);
        if (vault.Data.Entries.Count != expect.Entries.Count) problems.Add($"entry count {vault.Data.Entries.Count} != {expect.Entries.Count}");
        var mine = Describe(vault.Data.Entries).Entries.ToDictionary(e => e.Id);
        foreach (var want in expect.Entries)
        {
            if (!mine.TryGetValue(want.Id, out var got)) { problems.Add("missing entry " + want.Id); continue; }
            void Same(string field, string? a, string? b) { if (a != b) problems.Add($"{want.Name}.{field}: «{a}» != «{b}»"); }
            Same("name", got.Name, want.Name);
            Same("provider", got.Provider, want.Provider);
            Same("key", got.Key, want.Key);
            Same("baseUrl", got.BaseUrl, want.BaseUrl);
            Same("envVar", got.EnvVar, want.EnvVar);
            Same("consoleUrl", got.ConsoleUrl, want.ConsoleUrl);
            Same("notes", got.Notes, want.Notes);
            Same("color", got.Color, want.Color);
            Same("masked", got.Masked, want.Masked);
            Same("bash", got.Bash, want.Bash);
            Same("dotEnv", got.DotEnv, want.DotEnv);
            if (!SameInstant(got.Created, want.Created)) problems.Add($"{want.Name}.created: {got.Created} != {want.Created}");
            if ((got.LastCopied is null) != (want.LastCopied is null) || got.LastCopied is not null && !SameInstant(got.LastCopied, want.LastCopied!))
                problems.Add($"{want.Name}.lastCopied: {got.LastCopied} != {want.LastCopied}");
        }
        return problems;
    }

    static bool SameInstant(string a, string b) =>
        Math.Abs((DateTimeOffset.Parse(a) - DateTimeOffset.Parse(b)).TotalMilliseconds) < 2;
}
