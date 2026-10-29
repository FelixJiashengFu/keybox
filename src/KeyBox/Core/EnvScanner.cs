using System.Collections;
using System.Text.RegularExpressions;

namespace KeyBox.Core;

public sealed record EnvCandidate(string Name, string Value, ProviderPreset? Guess, bool AlreadyStored);

/// <summary>Finds key-looking variables among the Windows user environment variables (HKCU\Environment).</summary>
public static partial class EnvScanner
{
    [GeneratedRegex(@"(API[_-]?KEY|ACCESS[_-]?KEY|_KEY$|^KEY_|TOKEN|SECRET|_PAT$)", RegexOptions.IgnoreCase)]
    private static partial Regex SecretName();

    public static bool LooksLikeSecret(string name) => SecretName().IsMatch(name);

    public static List<EnvCandidate> Scan(IEnumerable<ApiEntry> stored) =>
        Candidates(Environment.GetEnvironmentVariables(EnvironmentVariableTarget.User), stored);

    public static List<EnvCandidate> Candidates(IDictionary variables, IEnumerable<ApiEntry> stored)
    {
        var storedKeys = stored.Select(e => e.Key.Trim()).ToHashSet(StringComparer.Ordinal);
        return variables.Cast<DictionaryEntry>()
            .Select(d => (Name: d.Key?.ToString() ?? "", Value: (d.Value?.ToString() ?? "").Trim()))
            .Where(v => v.Value.Length >= 8 && LooksLikeSecret(v.Name))
            .Select(v => new EnvCandidate(v.Name, v.Value,
                Providers.GuessFromEnvVar(v.Name) ?? Providers.GuessFromKey(v.Value),
                storedKeys.Contains(v.Value)))
            .OrderBy(c => c.AlreadyStored).ThenBy(c => c.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public static ApiEntry ToEntry(EnvCandidate c) => new()
    {
        Name = c.Guess?.Name ?? c.Name,
        Provider = c.Guess?.Name ?? "",
        Key = c.Value,
        EnvVar = c.Name,
        BaseUrl = c.Guess?.BaseUrl ?? "",
        ConsoleUrl = c.Guess?.ConsoleUrl ?? "",
        Notes = "从用户环境变量 " + c.Name + " 导入",
    };
}
