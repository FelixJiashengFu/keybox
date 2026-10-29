import Foundation
import XCTest
@testable import KeyBoxCore

final class ProvidersTests: XCTestCase {
    func testGuessFromKeyPrefix() {
        XCTAssertEqual(Providers.guess(fromKey: "sk-ant-api03-xyz")?.name, "Anthropic")
        XCTAssertEqual(Providers.guess(fromKey: "sk-or-v1-abc")?.name, "OpenRouter")
        XCTAssertEqual(Providers.guess(fromKey: "sk-proj-abc")?.name, "OpenAI")
        XCTAssertEqual(Providers.guess(fromKey: "github_pat_11ABC")?.name, "GitHub")
        XCTAssertEqual(Providers.guess(fromKey: "AIzaSyA-1234")?.name, "Google Gemini")
        XCTAssertNil(Providers.guess(fromKey: "sk-0123456789"))
    }

    func testGuessFromEnvVar() {
        XCTAssertEqual(Providers.guess(fromEnvVar: "DEEPSEEK_API_KEY")?.name, "DeepSeek")
        XCTAssertEqual(Providers.guess(fromEnvVar: "HF_TOKEN")?.name, "Hugging Face")
        XCTAssertEqual(Providers.guess(fromEnvVar: "GH_TOKEN")?.name, "GitHub")
        XCTAssertNotEqual(Providers.guess(fromEnvVar: "MY_HF_TOKEN")?.name, "Hugging Face")
    }

    func testColours() {
        XCTAssertEqual(Providers.color(for: "DeepSeek", fallbackSeed: "x"), "#4D6BFE")
        XCTAssertEqual(Providers.color(for: "Foo Cloud", fallbackSeed: "x"), Providers.color(for: "foo cloud", fallbackSeed: "y"))
    }

    func testMaskAndSearch() {
        XCTAssertEqual(ApiEntry.mask("sk-0123456789abcdefWXYZ"), "sk-0" + String(repeating: "•", count: 12) + "WXYZ")
        XCTAssertEqual(ApiEntry.mask("short123"), String(repeating: "•", count: 10))
        let e = ApiEntry(name: "工作账号", provider: "OpenAI", envVar: "OPENAI_API_KEY", notes: "MolAstria 用")
        XCTAssertTrue(e.matches("openai molastria"))
        XCTAssertFalse(e.matches("openai deepseek"))
    }
}

final class SnippetsTests: XCTestCase {
    func testQuoting() {
        XCTAssertEqual(Snippets.powerShell("K", "a'b"), "$env:K = 'a''b'")
        XCTAssertEqual(Snippets.bash("K", "a'b"), "export K='a'\\''b'")
        XCTAssertEqual(Snippets.dotEnv("K", "abc123"), "K=abc123")
        XCTAssertEqual(Snippets.dotEnv("K", "a b\"c"), "K=\"a b\\\"c\"")
    }

    func testNames() {
        XCTAssertTrue(Snippets.isValidName("OPENAI_API_KEY"))
        XCTAssertTrue(Snippets.isValidName("_X1"))
        XCTAssertFalse(Snippets.isValidName("1ABC"))
        XCTAssertFalse(Snippets.isValidName("A-B"))
        XCTAssertFalse(Snippets.isValidName(""))
        XCTAssertFalse(Snippets.isValidName("密钥"))
    }
}

final class EnvTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("keybox-home-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testParsesShellAssignments() {
        let text = """
        export DEEPSEEK_API_KEY="sk-abc"
          export X_TOKEN='a b'
        OPENAI_API_KEY=sk-123 # comment
        export A_KEY='it'\\''s'
        export E_KEY="a\\"b"
        export B_KEY="$OTHER"
        export C_KEY=$(cat ~/.secret)
        # export D_KEY=commented
        export PATH=/usr/bin:$PATH
        alias ll='ls -l'
        """
        let found = Dictionary(EnvScanner.parseAssignments(text).map { ($0.name, $0.value) }, uniquingKeysWith: { $1 })
        XCTAssertEqual(found["DEEPSEEK_API_KEY"], "sk-abc")
        XCTAssertEqual(found["X_TOKEN"], "a b")
        XCTAssertEqual(found["OPENAI_API_KEY"], "sk-123")
        XCTAssertEqual(found["A_KEY"], "it's")
        XCTAssertEqual(found["E_KEY"], "a\"b")
        XCTAssertNil(found["B_KEY"], "needs expansion")
        XCTAssertNil(found["C_KEY"], "command substitution")
        XCTAssertNil(found["D_KEY"], "commented out")
        XCTAssertNil(found["PATH"])
    }

    func testScan() throws {
        try "export DEEPSEEK_API_KEY=\"sk-aaaaaaaaaaaaaaaa\"\nexport SOME_SECRET=short\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "export GITHUB_TOKEN=ghp_bbbbbbbbbbbbbbbbbbbb\n".write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        let env = ["STRIPE_SECRET_KEY": "sk_test_cccccccccccc", "HOME": "/Users/x", "DEEPSEEK_API_KEY": "sk-aaaaaaaaaaaaaaaa"]
        let stored = [ApiEntry(key: "ghp_bbbbbbbbbbbbbbbbbbbb")]
        let found = EnvScanner.scan(home: home, environment: env, stored: stored)
        XCTAssertEqual(found.map(\.name).sorted(), ["DEEPSEEK_API_KEY", "GITHUB_TOKEN", "STRIPE_SECRET_KEY"], "deduped, short and non-secret skipped")
        XCTAssertTrue(found.first { $0.name == "GITHUB_TOKEN" }!.alreadyStored)
        XCTAssertEqual(found.last?.name, "GITHUB_TOKEN", "already-stored ones sort last")
        XCTAssertEqual(found.first { $0.name == "STRIPE_SECRET_KEY" }?.guess?.name, "Stripe")
        XCTAssertEqual(found.first { $0.name == "DEEPSEEK_API_KEY" }?.source, "~/.zshrc")
        let entry = EnvScanner.toEntry(found.first { $0.name == "DEEPSEEK_API_KEY" }!)
        XCTAssertEqual(entry.provider, "DeepSeek")
        XCTAssertEqual(entry.baseUrl, "https://api.deepseek.com")
    }

    func testWritesZshrc() throws {
        let zshrc = ShellProfile.zshrc(home: home)
        try ShellProfile.set("DEEPSEEK_API_KEY", to: "sk-one", in: zshrc)
        XCTAssertEqual(ShellProfile.value(of: "DEEPSEEK_API_KEY", in: zshrc), "sk-one")

        try "alias ll='ls -l'\nexport DEEPSEEK_API_KEY=old\nexport PATH=/usr/bin\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zshrc.path)
        try ShellProfile.set("DEEPSEEK_API_KEY", to: "sk-it's", in: zshrc)
        let text = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertEqual(text, "alias ll='ls -l'\nexport DEEPSEEK_API_KEY='sk-it'\\''s'\nexport PATH=/usr/bin\n")
        XCTAssertEqual(ShellProfile.value(of: "DEEPSEEK_API_KEY", in: zshrc), "sk-it's")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: zshrc.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zshrc.path + ".keybox.bak"))
    }

    func testFollowsSymlinkedDotfile() throws {
        let real = home.appendingPathComponent("dotfiles-zshrc")
        try "export PATH=/usr/bin\n".write(to: real, atomically: true, encoding: .utf8)
        let link = ShellProfile.zshrc(home: home)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try ShellProfile.set("OPENAI_API_KEY", to: "sk-proj-x", in: link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertEqual(ShellProfile.value(of: "OPENAI_API_KEY", in: real), "sk-proj-x")
    }
}

final class KeychainTests: XCTestCase {
    func testStoreOpenAndStaleKey() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KEYBOX_KEYCHAIN_TESTS"] == "1",
                          "needs an unlocked throwaway keychain (CI sets one up)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keybox-kc-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = DataPaths(dir: dir)
        let vault = try Vault.create(at: paths.vault, password: "keychain-test-1", iterations: 100_000)
        try KeychainUnlock.store(vault, paths: paths)
        defer { KeychainUnlock.remove(paths) }
        XCTAssertEqual(KeychainUnlock.open(paths)?.isOpen, true)
        try vault.changePassword("another-password")
        XCTAssertNil(KeychainUnlock.open(paths), "stale key is refused")
        XCTAssertNil(KeychainUnlock.open(paths), "…and removed")
    }
}

/// Answers like an OpenAI-compatible API: "good-key" is accepted, anything else gets 401.
final class MockAPI: URLProtocol {
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        MockAPI.lastRequest = request
        let good = request.value(forHTTPHeaderField: "Authorization") == "Bearer good-key"
            || request.value(forHTTPHeaderField: "x-api-key") == "good-key"
        let path = request.url?.path ?? ""
        let (code, body): (Int, String) =
            !good ? (401, #"{"error":{"message":"invalid key"}}"#)
            : path.hasSuffix("/user/balance") ? (200, #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00"}]}"#)
            : (200, #"{"object":"list","data":[{"id":"a"},{"id":"b"},{"id":"c"}]}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAPI.self]
        return URLSession(configuration: config)
    }
}

final class KeyTesterTests: XCTestCase {
    func testOpenAICompatibleSuccess() async {
        let r = await KeyTester.test(ApiEntry(provider: "我的中转", key: "good-key", baseUrl: "https://relay.test/v1/"), session: MockAPI.session)
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.message.contains("可用模型 3 个"), r.message)
        XCTAssertEqual(MockAPI.lastRequest?.url?.absoluteString, "https://relay.test/v1/models")
    }

    func testRejectedKey() async {
        let r = await KeyTester.test(ApiEntry(provider: "我的中转", key: "bad-key", baseUrl: "https://relay.test/v1"), session: MockAPI.session)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("401") && r.message.contains("invalid key"), r.message)
    }

    func testDeepSeekAddsBalance() async {
        let r = await KeyTester.test(ApiEntry(provider: "DeepSeek", key: "good-key", baseUrl: "https://ds.test"), session: MockAPI.session)
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.message.contains("余额 ¥110.00"), r.message)
    }

    func testAnthropicUsesApiKeyHeader() async {
        let r = await KeyTester.test(ApiEntry(provider: "Anthropic", key: "good-key", baseUrl: "https://claude.test"), session: MockAPI.session)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(MockAPI.lastRequest?.url?.absoluteString, "https://claude.test/v1/models")
        XCTAssertNotNil(MockAPI.lastRequest?.value(forHTTPHeaderField: "anthropic-version"))
    }

    func testUnknownProviderWithoutBaseUrlIsNotTestable() {
        XCTAssertFalse(KeyTester.canTest(ApiEntry(provider: "某云", key: "k")))
    }
}
