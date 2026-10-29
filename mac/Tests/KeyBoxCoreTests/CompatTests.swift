import Foundation
import XCTest
@testable import KeyBoxCore

/// The Mac and Windows versions must read each other's vault.json. tests/fixtures/windows-vault.json is
/// written by the Windows test suite (`KeyBox.Tests --write-fixture`); this suite opens it, and writes
/// mac-vault.json for the Windows suite to open in turn (CI uploads it as an artifact).
final class CompatTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()           // KeyBoxCoreTests
        .appendingPathComponent("../../../tests/fixtures")
        .standardizedFileURL

    struct Expect: Codable {
        let password: String
        let entries: [Entry]
    }

    struct Entry: Codable {
        let id, name, provider, key, baseUrl, envVar, consoleUrl, notes, color, masked, bash, dotEnv, created: String
        let lastCopied: String?
    }

    func testOpensVaultWrittenByWindows() throws {
        let expect = try JSONDecoder().decode(Expect.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("windows-expect.json")))
        let vault = try Vault.open(at: Self.fixtures.appendingPathComponent("windows-vault.json"), password: expect.password)
        XCTAssertEqual(vault.data.entries.count, expect.entries.count)
        for want in expect.entries {
            let got = try XCTUnwrap(vault.data.entries.first { $0.id == want.id }, "missing \(want.name)")
            XCTAssertEqual(got.name, want.name)
            XCTAssertEqual(got.provider, want.provider)
            XCTAssertEqual(got.key, want.key)
            XCTAssertEqual(got.baseUrl, want.baseUrl)
            XCTAssertEqual(got.envVar, want.envVar)
            XCTAssertEqual(got.consoleUrl, want.consoleUrl)
            XCTAssertEqual(got.notes, want.notes)
            XCTAssertEqual(got.color, want.color, "avatar colour must match Windows")
            XCTAssertEqual(got.maskedKey, want.masked)
            XCTAssertEqual(Snippets.bash(got.envVar, got.key), want.bash)
            XCTAssertEqual(Snippets.dotEnv(got.envVar, got.key), want.dotEnv)
            XCTAssertEqual(got.created.timeIntervalSince1970, try XCTUnwrap(ISODate.parse(want.created)).timeIntervalSince1970, accuracy: 0.002)
            if let copied = want.lastCopied {
                XCTAssertEqual(try XCTUnwrap(got.lastCopied).timeIntervalSince1970, try XCTUnwrap(ISODate.parse(copied)).timeIntervalSince1970, accuracy: 0.002)
            } else {
                XCTAssertNil(got.lastCopied)
            }
        }
    }

    func testWritesVaultForWindows() throws {
        let out = ProcessInfo.processInfo.environment["KEYBOX_FIXTURE_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("keybox-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = out.appendingPathComponent("mac-vault.json")
        try? FileManager.default.removeItem(at: file)

        let password = "fixture-密码-123"
        let vault = try Vault.create(at: file, password: password)
        var a = ApiEntry(name: "OpenRouter 备用", provider: "OpenRouter", key: "sk-or-v1-fixture0123456789",
                         baseUrl: "https://openrouter.ai/api/v1", envVar: "OPENROUTER_API_KEY",
                         consoleUrl: "https://openrouter.ai/settings/keys",
                         notes: "来自 Mac 的条目\n第二行 \"双引号\" 'single' \\ 反斜杠")
        a.lastCopied = Date(timeIntervalSince1970: 1_793_000_000.456)
        let b = ApiEntry(name: "Mac 自定义", provider: "某某云", key: "custom'key#2=x", baseUrl: "https://cloud.example.cn/v1", envVar: "MOU_API_KEY")
        vault.data.entries = [a, b]
        try vault.save()
        try? FileManager.default.removeItem(at: out.appendingPathComponent("mac-vault.json.bak"))

        let expect = Expect(password: password, entries: vault.data.entries.map { e in
            Entry(id: e.id, name: e.name, provider: e.provider, key: e.key, baseUrl: e.baseUrl, envVar: e.envVar,
                  consoleUrl: e.consoleUrl, notes: e.notes, color: e.color, masked: e.maskedKey,
                  bash: Snippets.bash(e.envVar, e.key), dotEnv: Snippets.dotEnv(e.envVar, e.key),
                  created: ISODate.format(e.created), lastCopied: e.lastCopied.map(ISODate.format))
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(expect).write(to: out.appendingPathComponent("mac-expect.json"))

        let again = try Vault.open(at: file, password: password)
        XCTAssertEqual(again.data.entries.map(\.id), vault.data.entries.map(\.id))
        XCTAssertEqual(again.data.entries.map(\.notes), vault.data.entries.map(\.notes))
    }
}
