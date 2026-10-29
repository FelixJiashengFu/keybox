#if DEBUG
import AppKit
import KeyBoxCore

/// `KeyBox --data <empty dir> --ui-snapshot <dir>` (debug builds only, used by CI): drives the real window
/// through the main flows with the same model calls the buttons make, checks the results, saves a
/// screenshot of each screen, then quits with status 0 (all passed) or 1.
@MainActor
enum SnapshotRun {
    static func start(model: VaultModel, outputDir: URL) {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            let runner = Runner(model: model, dir: outputDir)
            let code = await runner.run()
            fflush(stdout)
            exit(code)
        }
    }
}

@MainActor
private final class Runner {
    let model: VaultModel
    let dir: URL
    var failures: [String] = []

    init(model: VaultModel, dir: URL) {
        self.model = model
        self.dir = dir
    }

    func check(_ name: String, _ ok: Bool) {
        print((ok ? "  ok   " : "  FAIL ") + name)
        if !ok { failures.append(name) }
    }

    func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title == "密钥匣" } ?? NSApp.windows.first { $0.isVisible }
    }

    /// Renders the window's own views into a PNG (no screen-recording permission needed), plus a
    /// best-effort `screencapture` of the same window for comparison.
    func shot(_ name: String, _ window: NSWindow? = nil) async {
        await pause(0.7)
        guard let w = window ?? mainWindow, let view = w.contentView?.superview ?? w.contentView else {
            check("window for \(name)", false)
            return
        }
        view.layoutSubtreeIfNeeded()
        view.display()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(w.windowNumber), dir.appendingPathComponent(name + "-sc.png").path]
        try? p.run()
        p.waitUntilExit()
    }

    func run() async -> Int32 {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        model.homeDir = model.paths.dir.appendingPathComponent("home")
        try? fm.createDirectory(at: model.homeDir, withIntermediateDirectories: true)
        model.settings.clipboardSeconds = 2
        await pause(1.5)

        let password = "test-password-123"
        let claudeKey = "sk-ant-api03-FAKEkeyForUiTest000000000000000abcd"
        let deepseekKey = "sk-0123456789abcdef0123456789abcd"

        check("first run shows the create screen", model.isCreating && !model.isUnlocked)
        await shot("01-create")
        await model.create(password: "short", confirm: "short")
        check("too-short master password is refused", model.lockError?.contains("至少 8 位") == true)
        await model.create(password: password, confirm: password)
        check("vault is created and opened", model.isUnlocked && Vault.exists(at: model.paths.vault))
        await shot("02-empty")

        model.beginAdd()
        model.draft?.key = claudeKey
        model.draftKeyChanged()
        await pause(0.3)
        check("provider guessed from the sk-ant- prefix", model.draft?.provider == "Anthropic" && model.draft?.envVar == "ANTHROPIC_API_KEY")
        await shot("03-edit")
        model.saveDraft()
        check("saved and selected", model.selected?.key == claudeKey)
        check("detail shows the key masked", model.selected?.maskedKey == "sk-a" + String(repeating: "•", count: 12) + "abcd")
        await shot("04-detail")

        model.beginAdd()
        model.draft?.provider = "DeepSeek"
        model.draftProviderChanged()
        model.draft?.key = deepseekKey
        model.draft?.name = "DeepSeek 主账号"
        model.draft?.notes = "MolAstria 用 · 每月看一次余额"
        model.saveDraft()
        check("two entries, preset filled the env var", model.entries.count == 2 && model.selected?.envVar == "DEEPSEEK_API_KEY")
        await shot("05-deepseek")
        model.toggleReveal()
        check("reveal shows the full key", model.revealed)
        await shot("06-revealed")
        model.toggleReveal()

        if let e = model.selected {
            model.copyKey(e)
            let pb = NSPasteboard.general
            check("copy puts the key on the clipboard", pb.string(forType: .string) == deepseekKey)
            check("copy marks it concealed", pb.types?.contains(SecureClipboard.concealed) == true)
            await pause(3)
            check("clipboard cleared after 2 s", pb.string(forType: .string) != deepseekKey)

            model.writeToZshrc(e)
            let zshrc = (try? String(contentsOf: model.zshrcURL, encoding: .utf8)) ?? ""
            check("export line written to .zshrc", zshrc.contains("export DEEPSEEK_API_KEY='\(deepseekKey)'"))
            check(".zshrc status says it matches", model.zshrcStatus(e).hasPrefix("✓"))
        }

        model.beginAdd()
        model.draft?.key = deepseekKey
        model.saveDraft()
        check("duplicate key is refused", model.editError?.contains("已经保存在") == true)
        model.cancelEdit()

        model.search = "deep"
        check("search filters the list", model.filtered.count == 1)
        model.search = ""

        try? "export GITHUB_TOKEN=\"ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345\"\nexport PATH=/usr/bin\n"
            .write(to: model.homeDir.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        model.openImport()
        await pause(1)
        let found = model.importRequest?.candidates ?? []
        check("import finds GITHUB_TOKEN in ~/.zprofile", found.contains { $0.name == "GITHUB_TOKEN" && !$0.alreadyStored })
        check("import marks the stored DeepSeek key", found.contains { $0.name == "DEEPSEEK_API_KEY" && $0.alreadyStored })
        if let sheet = mainWindow?.attachedSheet { await shot("07-import", sheet) } else { check("import sheet is shown", false) }
        model.importSelected(found.filter { !$0.alreadyStored })
        check("imported", model.entries.count == 3)

        if let open = model.openSettings {
            open()
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        await pause(1.2)
        let main = mainWindow
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== main && $0.title != "密钥匣" }) {
            await shot("08-settings", settings)
            settings.close()
        } else {
            check("settings window opens", false)
        }

        model.lock()
        check("lock returns to the password screen", !model.isUnlocked && model.entries.isEmpty)
        await shot("09-locked")
        await model.unlock(password: "wrong-password")
        check("wrong password is refused", model.lockError?.contains("不对") == true)
        await model.unlock(password: password)
        check("unlock brings all entries back", model.entries.count == 3)

        if let e = model.selected { model.delete(e) }
        check("entry deleted", model.entries.count == 2)
        let onDisk = try? Vault.open(at: model.paths.vault, password: password)
        check("the file on disk has the 2 remaining entries", onDisk?.data.entries.count == 2)

        model.idleLimitOverride = 3
        await pause(9) // the idle timer ticks every 5 s
        check("locks itself when idle", !model.isUnlocked)

        print(failures.isEmpty ? "\nUI 冒烟测试全部通过" : "\n\(failures.count) 项失败：\(failures)")
        return failures.isEmpty ? 0 : 1
    }
}
#endif
