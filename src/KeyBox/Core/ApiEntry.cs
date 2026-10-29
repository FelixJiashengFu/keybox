using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace KeyBox.Core;

public sealed class ApiEntry : INotifyPropertyChanged
{
    string name = "", provider = "", key = "", baseUrl = "", envVar = "", consoleUrl = "", notes = "";
    DateTime? lastCopied;

    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get => name; set { if (Set(ref name, value)) Raise(nameof(Initial), nameof(DisplayName)); } }
    public string Provider { get => provider; set { if (Set(ref provider, value)) Raise(nameof(Subtitle), nameof(Color), nameof(Initial), nameof(DisplayName)); } }
    public string Key { get => key; set { if (Set(ref key, value)) Raise(nameof(MaskedKey)); } }
    public string BaseUrl { get => baseUrl; set => Set(ref baseUrl, value); }
    public string EnvVar { get => envVar; set { if (Set(ref envVar, value)) Raise(nameof(Subtitle)); } }
    public string ConsoleUrl { get => consoleUrl; set => Set(ref consoleUrl, value); }
    public string Notes { get => notes; set => Set(ref notes, value); }
    public DateTime Created { get; set; } = DateTime.Now;
    public DateTime Updated { get; set; } = DateTime.Now;
    public DateTime? LastCopied { get => lastCopied; set { if (Set(ref lastCopied, value)) Raise(nameof(LastCopiedText)); } }

    [JsonIgnore] public string DisplayName => Name.Trim().Length > 0 ? Name.Trim() : Provider.Trim().Length > 0 ? Provider.Trim() : "未命名";
    [JsonIgnore] public string Initial => DisplayName.Substring(0, char.IsSurrogate(DisplayName[0]) ? 2 : 1).ToUpperInvariant();
    [JsonIgnore] public string Subtitle => string.Join(" · ", new[] { Provider.Trim(), EnvVar.Trim() }.Where(s => s.Length > 0));
    [JsonIgnore] public string Color => Providers.ColorFor(Provider, DisplayName);
    [JsonIgnore] public string MaskedKey => Mask(Key);
    [JsonIgnore] public string LastCopiedText => LastCopied is { } t ? t.ToString("yyyy-MM-dd HH:mm") : "从未";

    public static string Mask(string secret)
    {
        secret = secret.Trim();
        if (secret.Length == 0) return "（空）";
        if (secret.Length <= 12) return new string('•', 10);
        return secret[..4] + new string('•', 12) + secret[^4..];
    }

    public ApiEntry Clone()
    {
        var copy = new ApiEntry();
        copy.CopyFrom(this);
        copy.Id = Id;
        copy.Created = Created;
        copy.Updated = Updated;
        copy.LastCopied = LastCopied;
        return copy;
    }

    /// <summary>Copies the user-editable fields.</summary>
    public void CopyFrom(ApiEntry other)
    {
        Name = other.Name.Trim();
        Provider = other.Provider.Trim();
        Key = other.Key.Trim();
        BaseUrl = other.BaseUrl.Trim();
        EnvVar = other.EnvVar.Trim();
        ConsoleUrl = other.ConsoleUrl.Trim();
        Notes = other.Notes.TrimEnd();
    }

    public bool Matches(string query)
    {
        if (string.IsNullOrWhiteSpace(query)) return true;
        foreach (var term in query.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            bool hit = Name.Contains(term, StringComparison.OrdinalIgnoreCase)
                || Provider.Contains(term, StringComparison.OrdinalIgnoreCase)
                || EnvVar.Contains(term, StringComparison.OrdinalIgnoreCase)
                || BaseUrl.Contains(term, StringComparison.OrdinalIgnoreCase)
                || Notes.Contains(term, StringComparison.OrdinalIgnoreCase);
            if (!hit) return false;
        }
        return true;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    bool Set<T>(ref T field, T value, [CallerMemberName] string property = "")
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(property);
        return true;
    }

    void Raise(params string[] names)
    {
        foreach (var n in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }
}
