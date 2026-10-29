import Foundation

public struct EnvCandidate: Identifiable, Hashable {
    public var id: String { name + "@" + source }
    public let name: String
    public let value: String
    /// Where it was found: a shell file such as ".zshrc", or "当前环境".
    public let source: String
    public let guess: ProviderPreset?
    public let alreadyStored: Bool
}

/// Finds key-looking variables in the user's shell startup files (~/.zshrc and friends) and in the
/// app's own environment. macOS has no user-level environment store like Windows' HKCU\Environment;
/// those files are where people keep `export OPENAI_API_KEY=…`.
public enum EnvScanner {
    public static let shellFiles = [".zshenv", ".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".profile"]

    static let secretName = try! NSRegularExpression(
        pattern: "(API[_-]?KEY|ACCESS[_-]?KEY|_KEY$|^KEY_|TOKEN|SECRET|_PAT$)", options: [.caseInsensitive])

    public static func looksLikeSecret(_ name: String) -> Bool {
        secretName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// `export NAME=value` / `NAME=value` lines with literal values. Values that need the shell to
    /// expand them ($VAR, $(…), `…`) are skipped.
    public static func parseAssignments(_ text: String) -> [(name: String, value: String)] {
        var found: [(name: String, value: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = Substring(raw).drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("export ") || line.hasPrefix("export\t") {
                line = line.dropFirst(7).drop { $0 == " " || $0 == "\t" }
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq])
            guard Snippets.isValidName(name), let value = shellWord(line[line.index(after: eq)...]) else { continue }
            found.append((name, value))
        }
        return found
    }

    /// Reads one shell word: '…' literal, "…" with \-escapes, bare characters up to whitespace or ';'.
    static func shellWord(_ s: Substring) -> String? {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            switch c {
            case " ", "\t", ";":
                return out
            case "'":
                guard let close = s[s.index(after: i)...].firstIndex(of: "'") else { return nil }
                out += s[s.index(after: i)..<close]
                i = s.index(after: close)
                continue
            case "\"":
                var j = s.index(after: i)
                var closed = false
                while j < s.endIndex {
                    let d = s[j]
                    if d == "\"" { closed = true; break }
                    if d == "$" || d == "`" { return nil }
                    if d == "\\", s.index(after: j) < s.endIndex, "\"\\$`".contains(s[s.index(after: j)]) {
                        j = s.index(after: j)
                    }
                    out.append(s[j])
                    j = s.index(after: j)
                }
                guard closed else { return nil }
                i = s.index(after: j)
                continue
            case "\\":
                let next = s.index(after: i)
                guard next < s.endIndex else { return out }
                out.append(s[next])
                i = s.index(after: next)
                continue
            case "$", "`":
                return nil
            default:
                out.append(c)
            }
            i = s.index(after: i)
        }
        return out
    }

    public static func scan(home: URL, environment: [String: String], stored: [ApiEntry]) -> [EnvCandidate] {
        var raw: [(name: String, value: String, source: String)] = []
        for file in shellFiles {
            guard let text = try? String(contentsOf: home.appendingPathComponent(file), encoding: .utf8) else { continue }
            raw += parseAssignments(text).map { (name: $0.name, value: $0.value, source: "~/" + file) }
        }
        raw += environment.map { (name: $0.key, value: $0.value, source: "当前环境") }

        let storedKeys = Set(stored.map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) })
        var seen = Set<String>()
        var result: [EnvCandidate] = []
        for r in raw {
            let value = r.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 8, looksLikeSecret(r.name), seen.insert(r.name + "=" + value).inserted else { continue }
            result.append(EnvCandidate(name: r.name, value: value, source: r.source,
                                       guess: Providers.guess(fromEnvVar: r.name) ?? Providers.guess(fromKey: value),
                                       alreadyStored: storedKeys.contains(value)))
        }
        return result.sorted {
            $0.alreadyStored != $1.alreadyStored ? !$0.alreadyStored
                : $0.name.caseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func toEntry(_ c: EnvCandidate) -> ApiEntry {
        ApiEntry(name: c.guess?.name ?? c.name, provider: c.guess?.name ?? "", key: c.value,
                 baseUrl: c.guess?.baseUrl ?? "", envVar: c.name, consoleUrl: c.guess?.consoleUrl ?? "",
                 notes: "从 \(c.source) 里的 \(c.name) 导入")
    }
}

/// Reads and writes `export NAME='value'` lines in a shell startup file (normally ~/.zshrc).
public enum ShellProfile {
    public static func zshrc(home: URL) -> URL { home.appendingPathComponent(".zshrc") }

    /// The value the file's last literal assignment of NAME sets, if any.
    public static func value(of name: String, in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return EnvScanner.parseAssignments(text).last { $0.name == name }?.value
    }

    /// Replaces existing `export NAME=`/`NAME=` lines, or appends one. Follows a symlinked dotfile,
    /// keeps the file's permissions, and leaves the previous version next to it as <file>.keybox.bak.
    public static func set(_ name: String, to value: String, in file: URL) throws {
        let target = file.resolvingSymlinksInPath()
        let fm = FileManager.default
        let old = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        let line = Snippets.bash(name, value)
        var lines = old.components(separatedBy: "\n")
        var replaced = false
        for i in lines.indices where isAssignment(lines[i], of: name) {
            lines[i] = line
            replaced = true
        }
        var text: String
        if replaced {
            text = lines.joined(separator: "\n")
        } else {
            text = old
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += "\n# added by KeyBox\n" + line + "\n"
        }
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        if fm.fileExists(atPath: target.path) {
            let backup = target.appendingPathExtension("keybox.bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: target, to: backup)
        }
        try text.write(to: target, atomically: true, encoding: .utf8)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
    }

    static func isAssignment(_ line: String, of name: String) -> Bool {
        var s = Substring(line).drop { $0 == " " || $0 == "\t" }
        if s.hasPrefix("export ") || s.hasPrefix("export\t") { s = s.dropFirst(7).drop { $0 == " " || $0 == "\t" } }
        return s.hasPrefix(name + "=")
    }
}
