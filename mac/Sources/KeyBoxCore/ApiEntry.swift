import Foundation

/// One stored key. Field names match the Windows version's JSON (camelCase).
public struct ApiEntry: Codable, Identifiable, Hashable {
    public var id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    public var name = ""
    public var provider = ""
    public var key = ""
    public var baseUrl = ""
    public var envVar = ""
    public var consoleUrl = ""
    public var notes = ""
    public var created = Date()
    public var updated = Date()
    public var lastCopied: Date?

    public init(name: String = "", provider: String = "", key: String = "", baseUrl: String = "",
                envVar: String = "", consoleUrl: String = "", notes: String = "") {
        self.name = name
        self.provider = provider
        self.key = key
        self.baseUrl = baseUrl
        self.envVar = envVar
        self.consoleUrl = consoleUrl
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, provider, key, baseUrl, envVar, consoleUrl, notes, created, updated, lastCopied
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        envVar = try c.decodeIfPresent(String.self, forKey: .envVar) ?? ""
        consoleUrl = try c.decodeIfPresent(String.self, forKey: .consoleUrl) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? created
        lastCopied = try c.decodeIfPresent(Date.self, forKey: .lastCopied)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(provider, forKey: .provider)
        try c.encode(key, forKey: .key)
        try c.encode(baseUrl, forKey: .baseUrl)
        try c.encode(envVar, forKey: .envVar)
        try c.encode(consoleUrl, forKey: .consoleUrl)
        try c.encode(notes, forKey: .notes)
        try c.encode(created, forKey: .created)
        try c.encode(updated, forKey: .updated)
        try c.encodeIfPresent(lastCopied, forKey: .lastCopied)
    }

    public var displayName: String {
        let n = name.trimmed, p = provider.trimmed
        return !n.isEmpty ? n : !p.isEmpty ? p : "未命名"
    }

    public var initial: String { String(displayName.prefix(1)).uppercased() }

    public var subtitle: String { [provider.trimmed, envVar.trimmed].filter { !$0.isEmpty }.joined(separator: " · ") }

    public var color: String { Providers.color(for: provider, fallbackSeed: displayName) }

    public var maskedKey: String { ApiEntry.mask(key) }

    public static func mask(_ secret: String) -> String {
        let s = secret.trimmed
        if s.isEmpty { return "（空）" }
        if s.count <= 12 { return String(repeating: "•", count: 10) }
        return String(s.prefix(4)) + String(repeating: "•", count: 12) + String(s.suffix(4))
    }

    /// Copies the user-editable fields, trimmed the same way the Windows version does.
    public mutating func copyFields(from other: ApiEntry) {
        name = other.name.trimmed
        provider = other.provider.trimmed
        key = other.key.trimmed
        baseUrl = other.baseUrl.trimmed
        envVar = other.envVar.trimmed
        consoleUrl = other.consoleUrl.trimmed
        notes = other.notes.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    public func matches(_ query: String) -> Bool {
        let terms = query.split(separator: " ").map(String.init)
        return terms.allSatisfy { t in
            [name, provider, envVar, baseUrl, notes].contains { $0.range(of: t, options: [.caseInsensitive]) != nil }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
