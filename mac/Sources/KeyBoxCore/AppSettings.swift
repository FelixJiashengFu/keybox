import Foundation

/// Non-secret preferences (settings.json next to vault.json; same keys as the Windows version).
public struct AppSettings: Codable, Equatable {
    /// Lock after this many idle minutes; 0 = never.
    public var autoLockMinutes = 5
    /// Clear a copied key from the clipboard after this many seconds; 0 = never.
    public var clipboardSeconds = 30
    /// Unlock with Touch ID / the Mac login password (key kept in the keychain). Mac only.
    public var quickUnlock = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoLockMinutes = try c.decodeIfPresent(Int.self, forKey: .autoLockMinutes) ?? 5
        clipboardSeconds = try c.decodeIfPresent(Int.self, forKey: .clipboardSeconds) ?? 30
        quickUnlock = try c.decodeIfPresent(Bool.self, forKey: .quickUnlock) ?? false
    }

    public static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Where KeyBox keeps its files: ~/Library/Application Support/KeyBox, or "--data DIR".
public struct DataPaths {
    public let dir: URL
    public var vault: URL { dir.appendingPathComponent("vault.json") }
    public var settings: URL { dir.appendingPathComponent("settings.json") }

    public init(dir: URL) {
        self.dir = dir.standardizedFileURL
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
    }

    public static func fromArguments(_ args: [String]) -> DataPaths {
        if let dir = argument("--data", in: args) { return DataPaths(dir: URL(fileURLWithPath: dir)) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DataPaths(dir: support.appendingPathComponent("KeyBox"))
    }

    public static func argument(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
