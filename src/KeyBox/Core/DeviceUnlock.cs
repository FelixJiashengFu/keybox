using System.IO;
using System.Security.Cryptography;
using System.Text.Json;

namespace KeyBox.Core;

/// <summary>
/// Optional "unlock without the master password on this PC": the vault key, wrapped with
/// Windows DPAPI (CurrentUser), so only this Windows account on this machine can unwrap it.
/// </summary>
public static class DeviceUnlock
{
    sealed class DeviceKeyFile
    {
        public string Salt { get; set; } = "";
        public string Key { get; set; } = "";
    }

    public static bool IsEnabled(DataPaths paths) => File.Exists(paths.DeviceKey);

    public static void Enable(DataPaths paths, Vault vault)
    {
        var key = vault.ExportKey();
        var salt = vault.Salt;
        try
        {
            var wrapped = ProtectedData.Protect(key, salt, DataProtectionScope.CurrentUser);
            var file = new DeviceKeyFile { Salt = Convert.ToBase64String(salt), Key = Convert.ToBase64String(wrapped) };
            File.WriteAllText(paths.DeviceKey, JsonSerializer.Serialize(file, Vault.Json));
        }
        finally { CryptographicOperations.ZeroMemory(key); }
    }

    public static void Disable(DataPaths paths)
    {
        if (File.Exists(paths.DeviceKey)) File.Delete(paths.DeviceKey);
    }

    /// <summary>Returns the opened vault, or null if the device key is missing or stale (it is then removed).</summary>
    public static Vault? TryOpen(DataPaths paths)
    {
        if (!IsEnabled(paths)) return null;
        byte[]? key = null;
        try
        {
            var file = JsonSerializer.Deserialize<DeviceKeyFile>(File.ReadAllText(paths.DeviceKey), Vault.Json);
            if (file is null) throw new InvalidDataException();
            key = ProtectedData.Unprotect(Convert.FromBase64String(file.Key), Convert.FromBase64String(file.Salt), DataProtectionScope.CurrentUser);
            return Vault.OpenWithKey(paths.Vault, key);
        }
        catch (Exception ex) when (ex is WrongPasswordException or CryptographicException or InvalidDataException or JsonException or FormatException)
        {
            Disable(paths);
            return null;
        }
        finally
        {
            if (key is not null) CryptographicOperations.ZeroMemory(key);
        }
    }
}
