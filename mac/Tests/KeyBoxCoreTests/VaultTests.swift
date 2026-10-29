import Foundation
import XCTest
@testable import KeyBoxCore

final class VaultTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("keybox-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    var file: URL { dir.appendingPathComponent("vault.json") }

    func makeVault(_ password: String = "correct horse 电池") throws -> Vault {
        let v = try Vault.create(at: file, password: password, iterations: 100_000)
        v.data.entries = [ApiEntry(name: "DeepSeek 主账号", provider: "DeepSeek", key: "sk-test-0123456789abcdef", envVar: "DEEPSEEK_API_KEY")]
        try v.save()
        return v
    }

    func testRoundTripAndNoPlaintextOnDisk() throws {
        _ = try makeVault()
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains("0123456789abcdef"))
        XCTAssertFalse(raw.contains("DeepSeek"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".bak"), "previous version kept as .bak")

        let reopened = try Vault.open(at: file, password: "correct horse 电池")
        XCTAssertEqual(reopened.data.entries.count, 1)
        XCTAssertEqual(reopened.data.entries[0].key, "sk-test-0123456789abcdef")
        XCTAssertEqual(reopened.data.entries[0].name, "DeepSeek 主账号")
    }

    func testWrongPassword() throws {
        _ = try makeVault()
        XCTAssertThrowsError(try Vault.open(at: file, password: "correct horse 电池!")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    func testPasswordIsUnicodeNormalised() throws {
        _ = try Vault.create(at: file, password: "caf\u{e9}-password", iterations: 100_000)
        XCTAssertTrue(try Vault.open(at: file, password: "cafe\u{301}-password").isOpen)
    }

    func mutateHeader(_ change: (inout [String: Any]) -> Void) throws -> URL {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        change(&json)
        let out = dir.appendingPathComponent("tampered.json")
        try JSONSerialization.data(withJSONObject: json).write(to: out)
        return out
    }

    func testTamperedCiphertextIsDetected() throws {
        _ = try makeVault()
        let bad = try mutateHeader { json in
            var blob = Data(base64Encoded: json["data"] as! String)!
            blob[3] ^= 0x01
            json["data"] = blob.base64EncodedString()
        }
        XCTAssertThrowsError(try Vault.open(at: bad, password: "correct horse 电池")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    func testTamperedHeaderIsDetected() throws {
        _ = try makeVault()
        let bad = try mutateHeader { json in
            var kdf = json["kdf"] as! [String: Any]
            kdf["iterations"] = 100_001
            json["kdf"] = kdf
        }
        XCTAssertThrowsError(try Vault.open(at: bad, password: "correct horse 电池")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    func testAbsurdIterationCountIsRefused() throws {
        _ = try makeVault()
        let bad = try mutateHeader { json in
            var kdf = json["kdf"] as! [String: Any]
            kdf["iterations"] = 10
            json["kdf"] = kdf
        }
        XCTAssertThrowsError(try Vault.open(at: bad, password: "correct horse 电池")) { error in
            guard case .corrupt? = error as? VaultError else { return XCTFail("expected corrupt, got \(error)") }
        }
    }

    func testChangePassword() throws {
        let v = try makeVault()
        XCTAssertTrue(v.checkPassword("correct horse 电池"))
        XCTAssertFalse(v.checkPassword("nope nope"))
        try v.changePassword("a brand new secret")
        XCTAssertEqual(try Vault.open(at: file, password: "a brand new secret").data.entries.count, 1)
        XCTAssertThrowsError(try Vault.open(at: file, password: "correct horse 电池"))
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((header["kdf"] as? [String: Any])?["iterations"] as? Int, Vault.defaultIterations)
    }

    func testOpenWithExportedKey() throws {
        let v = try makeVault()
        let again = try Vault.open(at: file, key: v.exportKey())
        XCTAssertEqual(again.data.entries.first?.key, "sk-test-0123456789abcdef")
        XCTAssertThrowsError(try Vault.open(at: file, key: Data(repeating: 7, count: 32))) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    func testCreateRefusesOverwriteAndCloseForgets() throws {
        let v = try makeVault()
        XCTAssertThrowsError(try Vault.create(at: file, password: "whatever123")) {
            XCTAssertEqual($0 as? VaultError, .alreadyExists)
        }
        v.close()
        XCTAssertFalse(v.isOpen)
        XCTAssertTrue(v.data.entries.isEmpty)
        XCTAssertThrowsError(try v.save()) { XCTAssertEqual($0 as? VaultError, .locked) }
    }

    func testDatesAsWrittenByDotNet() throws {
        let date = try XCTUnwrap(ISODate.parse("2026-10-29T16:08:48.7538952-04:00"))
        let utc = try XCTUnwrap(ISODate.parse("2026-10-29T20:08:48.7538952Z"))
        XCTAssertEqual(date.timeIntervalSince1970, utc.timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertEqual(date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.7538952, accuracy: 1e-6)
        XCTAssertNotNil(ISODate.parse("2026-10-29T20:08:48Z"))
        let now = Date()
        XCTAssertEqual(try XCTUnwrap(ISODate.parse(ISODate.format(now))).timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }
}
