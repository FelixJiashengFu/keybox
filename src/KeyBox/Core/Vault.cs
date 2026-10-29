using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace KeyBox.Core;

public sealed class WrongPasswordException() : Exception("主密码错误");

/// <summary>Everything inside the encrypted blob.</summary>
public sealed class VaultData
{
    public List<ApiEntry> Entries { get; set; } = [];
}

/// <summary>
/// vault.json: a small plaintext header (KDF parameters, nonce) plus one AES-256-GCM blob
/// holding the serialized <see cref="VaultData"/>. The key comes from PBKDF2-HMAC-SHA256
/// over the master password; the header is bound to the ciphertext as associated data.
/// </summary>
public sealed class Vault
{
    public const int DefaultIterations = 600_000;
    const int SaltSize = 16, KeySize = 32, NonceSize = 12, TagSize = 16;

    public static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public string FilePath { get; }
    public VaultData Data { get; private set; }
    byte[] key;
    byte[] salt;
    int iterations;

    Vault(string filePath, byte[] key, byte[] salt, int iterations, VaultData data)
    {
        FilePath = filePath;
        this.key = key;
        this.salt = salt;
        this.iterations = iterations;
        Data = data;
    }

    public byte[] Salt => (byte[])salt.Clone();
    public bool IsOpen => key.Length > 0;

    public static bool Exists(string filePath) => File.Exists(filePath);

    public static Vault Create(string filePath, string password, int iterations = DefaultIterations)
    {
        if (File.Exists(filePath)) throw new IOException("密钥库已存在：" + filePath);
        var salt = RandomNumberGenerator.GetBytes(SaltSize);
        var vault = new Vault(filePath, DeriveKey(password, salt, iterations), salt, iterations, new VaultData());
        vault.Save();
        return vault;
    }

    public static Vault Open(string filePath, string password)
    {
        var header = ReadHeader(filePath);
        var salt = Convert.FromBase64String(header.Kdf.Salt);
        var key = DeriveKey(password, salt, header.Kdf.Iterations);
        return Decrypt(filePath, header, key);
    }

    /// <summary>Opens with an already-derived key (quick unlock). Throws WrongPasswordException if it no longer fits.</summary>
    public static Vault OpenWithKey(string filePath, byte[] key)
    {
        var header = ReadHeader(filePath);
        return Decrypt(filePath, header, (byte[])key.Clone());
    }

    public byte[] ExportKey() => (byte[])key.Clone();

    public void Save()
    {
        if (!IsOpen) throw new InvalidOperationException("密钥库已锁定");
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(Data, Json);
        var nonce = RandomNumberGenerator.GetBytes(NonceSize);
        var blob = new byte[plaintext.Length + TagSize];
        using (var aes = new AesGcm(key, TagSize))
            aes.Encrypt(nonce, plaintext, blob.AsSpan(0, plaintext.Length), blob.AsSpan(plaintext.Length), Aad(iterations, salt));
        CryptographicOperations.ZeroMemory(plaintext);

        var header = new VaultHeader
        {
            Kdf = new KdfParams { Iterations = iterations, Salt = Convert.ToBase64String(salt) },
            Nonce = Convert.ToBase64String(nonce),
            Data = Convert.ToBase64String(blob),
        };
        WriteAtomically(FilePath, JsonSerializer.SerializeToUtf8Bytes(header, Json));
    }

    public sealed record PendingKey(byte[] Key, byte[] Salt, int Iterations);

    /// <summary>The slow half of a password change (PBKDF2); safe to run off the UI thread.</summary>
    public static PendingKey PrepareKey(string newPassword)
    {
        var newSalt = RandomNumberGenerator.GetBytes(SaltSize);
        return new(DeriveKey(newPassword, newSalt, DefaultIterations), newSalt, DefaultIterations);
    }

    /// <summary>Re-encrypts the vault under a key from <see cref="PrepareKey"/>.</summary>
    public void Rekey(PendingKey next)
    {
        if (!IsOpen) throw new InvalidOperationException("密钥库已锁定");
        CryptographicOperations.ZeroMemory(key);
        key = next.Key;
        salt = next.Salt;
        iterations = next.Iterations;
        Save();
    }

    public void ChangePassword(string newPassword) => Rekey(PrepareKey(newPassword));

    public bool CheckPassword(string password) =>
        CryptographicOperations.FixedTimeEquals(DeriveKey(password, salt, iterations), key);

    public void Close()
    {
        CryptographicOperations.ZeroMemory(key);
        key = [];
        Data = new VaultData();
    }

    static Vault Decrypt(string filePath, VaultHeader header, byte[] key)
    {
        var salt = Convert.FromBase64String(header.Kdf.Salt);
        var nonce = Convert.FromBase64String(header.Nonce);
        var blob = Convert.FromBase64String(header.Data);
        if (blob.Length < TagSize) throw new InvalidDataException("密钥库文件已损坏");
        var plaintext = new byte[blob.Length - TagSize];
        try
        {
            using var aes = new AesGcm(key, TagSize);
            aes.Decrypt(nonce, blob.AsSpan(0, plaintext.Length), blob.AsSpan(plaintext.Length), plaintext, Aad(header.Kdf.Iterations, salt));
        }
        catch (AuthenticationTagMismatchException)
        {
            CryptographicOperations.ZeroMemory(key);
            throw new WrongPasswordException();
        }
        var data = JsonSerializer.Deserialize<VaultData>(plaintext, Json) ?? new VaultData();
        CryptographicOperations.ZeroMemory(plaintext);
        return new Vault(filePath, key, salt, header.Kdf.Iterations, data);
    }

    static VaultHeader ReadHeader(string filePath)
    {
        var header = JsonSerializer.Deserialize<VaultHeader>(File.ReadAllBytes(filePath), Json)
            ?? throw new InvalidDataException("密钥库文件为空");
        if (header.Format != VaultHeader.FormatName || header.Version != 1 || header.Kdf.Name != KdfParams.Pbkdf2 || header.Cipher != VaultHeader.CipherName)
            throw new InvalidDataException("不认识的密钥库格式");
        if (header.Kdf.Iterations < 100_000) throw new InvalidDataException("密钥库参数异常");
        return header;
    }

    static byte[] DeriveKey(string password, byte[] salt, int iterations)
    {
        var bytes = Encoding.UTF8.GetBytes(password.Normalize(NormalizationForm.FormC));
        try { return Rfc2898DeriveBytes.Pbkdf2(bytes, salt, iterations, HashAlgorithmName.SHA256, KeySize); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    static byte[] Aad(int iterations, byte[] salt) =>
        Encoding.UTF8.GetBytes($"{VaultHeader.FormatName}|1|{KdfParams.Pbkdf2}|{iterations}|{Convert.ToBase64String(salt)}|{VaultHeader.CipherName}");

    /// <summary>Write to a temp file, then swap it in, keeping the previous version as .bak.</summary>
    static void WriteAtomically(string path, byte[] content)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var tmp = path + ".tmp";
        using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            fs.Write(content);
            fs.Flush(flushToDisk: true);
        }
        if (File.Exists(path)) File.Replace(tmp, path, path + ".bak", ignoreMetadataErrors: true);
        else File.Move(tmp, path);
    }

    sealed class VaultHeader
    {
        public const string FormatName = "keybox-vault", CipherName = "AES-256-GCM";
        public string Format { get; set; } = FormatName;
        public int Version { get; set; } = 1;
        public KdfParams Kdf { get; set; } = new();
        public string Cipher { get; set; } = CipherName;
        public string Nonce { get; set; } = "";
        public string Data { get; set; } = "";
    }

    sealed class KdfParams
    {
        public const string Pbkdf2 = "PBKDF2-HMAC-SHA256";
        public string Name { get; set; } = Pbkdf2;
        public int Iterations { get; set; }
        public string Salt { get; set; } = "";
    }
}
