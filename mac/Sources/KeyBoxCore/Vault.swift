import CommonCrypto
import CryptoKit
import Foundation

public enum VaultError: Error, Equatable, LocalizedError {
    case wrongPassword
    case corrupt(String)
    case alreadyExists
    case locked

    public var errorDescription: String? {
        switch self {
        case .wrongPassword: return "主密码错误"
        case .corrupt(let why): return "密钥库文件有问题：" + why
        case .alreadyExists: return "密钥库已经存在"
        case .locked: return "密钥库已锁定"
        }
    }
}

/// Everything inside the encrypted blob.
public struct VaultData: Codable {
    public var entries: [ApiEntry] = []
    public init(entries: [ApiEntry] = []) { self.entries = entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([ApiEntry].self, forKey: .entries) ?? []
    }
}

/// vault.json — the same format as the Windows version (src/KeyBox/Core/Vault.cs), so the file can be
/// copied between the two: a plaintext header (KDF parameters, nonce) plus one AES-256-GCM blob holding
/// the JSON-encoded VaultData. The key is PBKDF2-HMAC-SHA256 over the NFC-normalised master password;
/// the header is bound to the ciphertext as associated data.
public final class Vault {
    public static let defaultIterations = 600_000
    static let formatName = "keybox-vault", cipherName = "AES-256-GCM", kdfName = "PBKDF2-HMAC-SHA256"
    static let saltSize = 16, keySize = 32, nonceSize = 12, tagSize = 16

    public let fileURL: URL
    public var data: VaultData
    private var key: Data
    private var salt: Data
    private var iterations: Int

    private init(fileURL: URL, key: Data, salt: Data, iterations: Int, data: VaultData) {
        self.fileURL = fileURL
        self.key = key
        self.salt = salt
        self.iterations = iterations
        self.data = data
    }

    public var isOpen: Bool { !key.isEmpty }
    public var saltData: Data { salt }

    public static func exists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public static func create(at url: URL, password: String, iterations: Int = defaultIterations) throws -> Vault {
        if exists(at: url) { throw VaultError.alreadyExists }
        let salt = randomBytes(saltSize)
        let vault = Vault(fileURL: url, key: deriveKey(password, salt: salt, iterations: iterations),
                          salt: salt, iterations: iterations, data: VaultData())
        try vault.save()
        return vault
    }

    public static func open(at url: URL, password: String) throws -> Vault {
        let header = try readHeader(url)
        guard let salt = Data(base64Encoded: header.kdf.salt) else { throw VaultError.corrupt("salt") }
        return try decrypt(url, header: header, key: deriveKey(password, salt: salt, iterations: header.kdf.iterations))
    }

    /// Opens with an already-derived key (Touch ID unlock). Throws wrongPassword if it no longer fits.
    public static func open(at url: URL, key: Data) throws -> Vault {
        try decrypt(url, header: try readHeader(url), key: key)
    }

    public func exportKey() -> Data { key }

    public func save() throws {
        guard isOpen else { throw VaultError.locked }
        let plaintext = try Vault.jsonEncoder().encode(data)
        let nonce = Vault.randomBytes(Vault.nonceSize)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                      nonce: AES.GCM.Nonce(data: nonce),
                                      authenticating: Vault.aad(iterations: iterations, salt: salt))
        let header = Header(kdf: Kdf(iterations: iterations, salt: salt.base64EncodedString()),
                            nonce: nonce.base64EncodedString(),
                            data: (sealed.ciphertext + sealed.tag).base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try Vault.writeKeepingBackup(try encoder.encode(header), to: fileURL)
    }

    public struct PendingKey: Sendable {
        let key: Data, salt: Data, iterations: Int
    }

    /// The slow half of a password change (PBKDF2); fine to run off the main thread.
    public static func prepareKey(_ newPassword: String) -> PendingKey {
        let salt = randomBytes(saltSize)
        return PendingKey(key: deriveKey(newPassword, salt: salt, iterations: defaultIterations), salt: salt, iterations: defaultIterations)
    }

    /// Re-encrypts the vault under a key from prepareKey.
    public func rekey(_ next: PendingKey) throws {
        guard isOpen else { throw VaultError.locked }
        key = next.key
        salt = next.salt
        iterations = next.iterations
        try save()
    }

    public func changePassword(_ newPassword: String) throws { try rekey(Vault.prepareKey(newPassword)) }

    public func checkPassword(_ password: String) -> Bool {
        isOpen && Vault.deriveKey(password, salt: salt, iterations: iterations) == key
    }

    public func close() {
        key.resetBytes(in: 0..<key.count)
        key = Data()
        data = VaultData()
    }

    // MARK: - format

    struct Header: Codable {
        var format = Vault.formatName
        var version = 1
        var kdf: Kdf
        var cipher = Vault.cipherName
        var nonce: String
        var data: String
    }

    struct Kdf: Codable {
        var name = Vault.kdfName
        var iterations: Int
        var salt: String
    }

    static func readHeader(_ url: URL) throws -> Header {
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: try Data(contentsOf: url)) }
        catch let error as DecodingError { throw VaultError.corrupt(String(describing: error)) }
        guard header.format == formatName, header.version == 1, header.kdf.name == kdfName, header.cipher == cipherName
        else { throw VaultError.corrupt("不认识的密钥库格式") }
        guard header.kdf.iterations >= 100_000 else { throw VaultError.corrupt("参数异常") }
        return header
    }

    static func decrypt(_ url: URL, header: Header, key: Data) throws -> Vault {
        guard let salt = Data(base64Encoded: header.kdf.salt),
              let nonce = Data(base64Encoded: header.nonce),
              let blob = Data(base64Encoded: header.data),
              blob.count >= tagSize
        else { throw VaultError.corrupt("base64") }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: blob.prefix(blob.count - tagSize),
                                            tag: blob.suffix(tagSize))
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key),
                                         authenticating: aad(iterations: header.kdf.iterations, salt: salt))
        } catch CryptoKitError.authenticationFailure {
            throw VaultError.wrongPassword
        }
        let data: VaultData
        do { data = try jsonDecoder().decode(VaultData.self, from: plaintext) }
        catch { throw VaultError.corrupt(String(describing: error)) }
        return Vault(fileURL: url, key: key, salt: salt, iterations: header.kdf.iterations, data: data)
    }

    static func aad(iterations: Int, salt: Data) -> Data {
        Data("\(formatName)|1|\(kdfName)|\(iterations)|\(salt.base64EncodedString())|\(cipherName)".utf8)
    }

    static func deriveKey(_ password: String, salt: Data, iterations: Int) -> Data {
        let bytes = Array(password.precomposedStringWithCanonicalMapping.utf8).map { CChar(bitPattern: $0) }
        var out = [UInt8](repeating: 0, count: keySize)
        let status = salt.withUnsafeBytes { (saltBuffer: UnsafeRawBufferPointer) -> Int32 in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes, bytes.count,
                                 saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                 &out, out.count)
        }
        precondition(status == Int32(kCCSuccess), "PBKDF2 failed: \(status)")
        return Data(out)
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "no randomness")
        return Data(bytes)
    }

    /// Writes atomically (temp file + rename), keeping the previous version as vault.json.bak.
    static func writeKeepingBackup(_ content: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        try content.write(to: url, options: .atomic)
    }

    // Dates are written like .NET does (ISO 8601 with the local UTC offset) and read with up to 7
    // fractional digits, which is what the Windows version writes.
    public static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(ISODate.format(date))
        }
        return encoder
    }

    public static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = ISODate.parse(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date " + text)
            }
            return date
        }
        return decoder
    }
}

public enum ISODate {
    public static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f.string(from: date)
    }

    /// Accepts "2026-10-29T16:08:48.7538952-04:00", "...Z", or no fraction at all.
    public static func parse(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
        else { return f.date(from: text) }
        guard let whole = f.date(from: String(text[..<dot]) + String(text[zone...])) else { return nil }
        let digits = text[text.index(after: dot)..<zone]
        guard let fraction = Double("0." + digits) else { return nil }
        return whole.addingTimeInterval(fraction)
    }
}

// The app hands a freshly opened Vault from a background task (PBKDF2) back to the main actor;
// after that it is only used there.
extension Vault: @unchecked Sendable {}
