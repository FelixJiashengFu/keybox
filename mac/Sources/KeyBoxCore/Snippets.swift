import Foundation

/// Ready-to-paste lines that set an environment variable to a key (same quoting as the Windows version).
public enum Snippets {
    public static func bash(_ name: String, _ value: String) -> String {
        "export \(name)='\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    public static func powerShell(_ name: String, _ value: String) -> String {
        "$env:\(name) = '\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    public static func dotEnv(_ name: String, _ value: String) -> String {
        guard value.contains(where: { " #\"'=\\".contains($0) }) else { return "\(name)=\(value)" }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\(name)=\"\(escaped)\""
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0)) }
    }
}
