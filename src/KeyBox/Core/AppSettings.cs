using System.IO;
using System.Text.Json;

namespace KeyBox.Core;

/// <summary>Non-secret preferences (settings.json next to vault.json).</summary>
public sealed class AppSettings
{
    /// <summary>Lock after this many idle minutes; 0 = never.</summary>
    public int AutoLockMinutes { get; set; } = 5;
    /// <summary>Clear a copied key from the clipboard after this many seconds; 0 = never.</summary>
    public int ClipboardSeconds { get; set; } = 30;

    public static AppSettings Load(string path)
    {
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), Vault.Json) ?? new();
        }
        catch (JsonException) { }
        return new();
    }

    public void Save(string path) => File.WriteAllText(path, JsonSerializer.Serialize(this, Vault.Json));
}

/// <summary>Where KeyBox keeps its files. Default %APPDATA%\KeyBox; "--data DIR" overrides.</summary>
public sealed class DataPaths(string dir)
{
    public string Dir { get; } = Path.GetFullPath(dir);
    public string Vault => Path.Combine(Dir, "vault.json");
    public string Settings => Path.Combine(Dir, "settings.json");
    public string DeviceKey => Path.Combine(Dir, "device.key");

    public static DataPaths FromArgs(string[] args)
    {
        var i = Array.IndexOf(args, "--data");
        var dir = i >= 0 && i + 1 < args.Length
            ? args[i + 1]
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "KeyBox");
        Directory.CreateDirectory(dir);
        return new DataPaths(dir);
    }
}
