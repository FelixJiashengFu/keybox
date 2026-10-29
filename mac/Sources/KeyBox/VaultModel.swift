import AppKit
import KeyBoxCore
import LocalAuthentication
import SwiftUI

struct ImportRequest: Identifiable {
    let id = UUID()
    let candidates: [EnvCandidate]
}

/// Everything the window shows, and every action its buttons take. Mirrors MainWindow.xaml.cs.
@MainActor
final class VaultModel: ObservableObject {
    let paths: DataPaths
    /// Where ~/.zshrc and friends are read and written (the snapshot run points it at a temp folder).
    var homeDir = FileManager.default.homeDirectoryForCurrentUser
    /// Seconds before the idle lock, overriding settings (snapshot run only).
    var idleLimitOverride: TimeInterval?

    @Published var settings: AppSettings { didSet { if settings != oldValue { settings.save(to: paths.settings) } } }
    @Published private(set) var vault: Vault?
    @Published private(set) var entries: [ApiEntry] = []
    @Published var selection: ApiEntry.ID? { didSet { if selection != oldValue { revealed = false; cancelTest() } } }
    @Published var search = "" { didSet { keepSelectionVisible() } }

    @Published var draft: ApiEntry?
    @Published private(set) var editingID: String?
    @Published var editError: String?
    @Published var keyGuessHint: String?

    @Published var lockMessage: String?
    @Published var lockError: String?
    @Published private(set) var busy = false

    @Published var toast: String?
    @Published var revealed = false
    @Published private(set) var testing = false
    @Published private(set) var testResult: TestResult?
    @Published var importRequest: ImportRequest?
    @Published private(set) var shellRevision = 0

    private var draftPreset: ProviderPreset?
    private var failedAttempts = 0
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var toastTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var testTask: Task<Void, Never>?

    init(paths: DataPaths) {
        self.paths = paths
        settings = AppSettings.load(from: paths.settings)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIdle() }
        }
    }

    // MARK: state

    var isUnlocked: Bool { vault != nil }
    var isCreating: Bool { !Vault.exists(at: paths.vault) }

    var filtered: [ApiEntry] {
        let zh = Locale(identifier: "zh_CN")
        return entries.filter { $0.matches(search) }
            .sorted { $0.displayName.compare($1.displayName, locale: zh) == .orderedAscending }
    }

    var selected: ApiEntry? { entries.first { $0.id == selection } }
    func entry(_ id: ApiEntry.ID) -> ApiEntry? { entries.first { $0.id == id } }

    var quickUnlockReady: Bool { settings.quickUnlock && !isCreating }
    var autoQuickUnlockTried = false

    lazy var biometryName: String = {
        let ctx = LAContext()
        var error: NSError?
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return ctx.biometryType == .touchID ? "Touch ID" : "Mac 登录密码"
    }()

    // MARK: lock / unlock

    func create(password: String, confirm: String) async {
        guard !busy else { return }
        if password.count < 8 { lockError = "主密码至少 8 位。可以用一句只有你知道的话。"; return }
        if password != confirm { lockError = "两次输入的主密码不一样。"; return }
        busy = true
        lockError = nil
        let url = paths.vault
        do {
            let opened = try await Task.detached { try Vault.create(at: url, password: password) }.value
            busy = false
            didUnlock(opened)
            showToast("密钥匣已创建，开始添加你的第一个 Key 吧")
        } catch {
            busy = false
            lockError = "创建失败：" + error.localizedDescription
        }
    }

    func unlock(password: String) async {
        guard !busy else { return }
        if password.isEmpty { lockError = "请输入主密码。"; return }
        busy = true
        lockError = nil
        let url = paths.vault
        do {
            let opened = try await Task.detached { try Vault.open(at: url, password: password) }.value
            busy = false
            failedAttempts = 0
            didUnlock(opened)
        } catch VaultError.wrongPassword {
            failedAttempts += 1
            try? await Task.sleep(nanoseconds: UInt64(min(failedAttempts, 6)) * 300_000_000) // slow down guessing
            busy = false
            lockError = "主密码不对，再试一次。"
        } catch {
            busy = false
            lockError = "打不开密钥库文件：" + error.localizedDescription
        }
    }

    func quickUnlock() async {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "输入主密码"
        do {
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁你保存的 API Key") else { return }
        } catch {
            return // cancelled, or no Touch ID / password available
        }
        guard let opened = KeychainUnlock.open(paths) else {
            settings.quickUnlock = false
            lockError = "免密解锁已失效（主密码可能改过），请输入主密码。"
            return
        }
        didUnlock(opened)
    }

    private func didUnlock(_ opened: Vault) {
        vault = opened
        entries = opened.data.entries
        search = ""
        lockMessage = nil
        lockError = nil
        lastActivity = Date()
        selection = filtered.first?.id
    }

    func lock(_ reason: String? = nil) {
        guard let v = vault else { return }
        cancelTest()
        SecureClipboard.clearIfOurs()
        draft = nil
        editingID = nil
        importRequest = nil
        v.close()
        vault = nil
        entries = []
        selection = nil
        revealed = false
        toast = nil
        lockMessage = reason
    }

    func noteActivity() { lastActivity = Date() }

    private func checkIdle() {
        guard isUnlocked else { return }
        let limit = idleLimitOverride ?? TimeInterval(settings.autoLockMinutes * 60)
        guard limit > 0, Date().timeIntervalSince(lastActivity) >= limit else { return }
        lock(settings.autoLockMinutes > 0 ? "空闲 \(settings.autoLockMinutes) 分钟，已自动锁定" : "已自动锁定")
    }

    // MARK: list

    private func persist() {
        guard let v = vault else { return }
        v.data.entries = entries
        do { try v.save() } catch { showToast("保存失败：" + error.localizedDescription) }
    }

    private func keepSelectionVisible() {
        let list = filtered
        if let s = selection, list.contains(where: { $0.id == s }) { return }
        selection = list.first?.id
    }

    func delete(_ e: ApiEntry) {
        guard isUnlocked else { return }
        let index = filtered.firstIndex { $0.id == e.id } ?? 0
        entries.removeAll { $0.id == e.id }
        persist()
        let after = filtered
        selection = after.isEmpty ? nil : after[min(index, after.count - 1)].id
        showToast("已删除「\(e.displayName)」")
    }

    // MARK: copy / reveal / test

    func copyKey(_ e: ApiEntry) { copySecret(e, e.key, "「\(e.displayName)」的 Key") }
    func copyExport(_ e: ApiEntry) { copySecret(e, Snippets.bash(e.envVar, e.key), " export 命令") }
    func copyDotEnv(_ e: ApiEntry) { copySecret(e, Snippets.dotEnv(e.envVar, e.key), " .env 行") }

    private func copySecret(_ e: ApiEntry, _ text: String, _ what: String) {
        SecureClipboard.copySecret(text, clearAfter: settings.clipboardSeconds)
        if let i = entries.firstIndex(where: { $0.id == e.id }) {
            entries[i].lastCopied = Date()
            persist()
        }
        let s = settings.clipboardSeconds
        showToast(s > 0 ? "已复制\(what)，\(s) 秒后自动从剪贴板清除" : "已复制\(what)")
    }

    func copyPlain(_ text: String, _ what: String) {
        SecureClipboard.copyPlain(text)
        showToast("已复制" + what)
    }

    func toggleReveal() {
        revealed.toggle()
        revealTask?.cancel()
        guard revealed else { return }
        revealTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if !Task.isCancelled { self?.revealed = false }
        }
    }

    func test(_ e: ApiEntry) {
        cancelTest()
        testing = true
        let id = e.id
        testTask = Task { [weak self] in
            let result = await KeyTester.test(e)
            guard let self, !Task.isCancelled, self.selection == id else { return }
            self.testResult = result
            self.testing = false
        }
    }

    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testing = false
        testResult = nil
    }

    // MARK: ~/.zshrc

    var zshrcURL: URL { ShellProfile.zshrc(home: homeDir) }

    func zshrcStatus(_ e: ApiEntry) -> String {
        _ = shellRevision
        guard Snippets.isValidName(e.envVar) else { return "变量名不合规（只能用英文字母、数字和下划线）" }
        guard let current = ShellProfile.value(of: e.envVar, in: zshrcURL) else { return "~/.zshrc 里还没有 \(e.envVar)" }
        return current == e.key ? "✓ ~/.zshrc 里的 \(e.envVar) 就是这个 Key" : "~/.zshrc 里的 \(e.envVar) 是另一个值"
    }

    func writeToZshrc(_ e: ApiEntry) {
        do {
            try ShellProfile.set(e.envVar, to: e.key, in: zshrcURL)
            shellRevision += 1
            showToast("已写入 ~/.zshrc，新开的终端生效")
        } catch {
            showToast("写入失败：" + error.localizedDescription)
        }
    }

    // MARK: add / edit

    func beginAdd() {
        guard isUnlocked, draft == nil else { return }
        startEdit(ApiEntry(), editing: nil)
    }

    func beginEdit(_ e: ApiEntry) {
        guard isUnlocked, draft == nil else { return }
        selection = e.id
        startEdit(e, editing: e.id)
    }

    private func startEdit(_ e: ApiEntry, editing id: String?) {
        cancelTest()
        editingID = id
        draftPreset = Providers.find(e.provider)
        editError = nil
        keyGuessHint = nil
        draft = e
    }

    func cancelEdit() {
        draft = nil
        editingID = nil
        editError = nil
        keyGuessHint = nil
    }

    /// Fill the fields that are empty or still hold the previous provider's defaults.
    func draftProviderChanged() {
        guard var d = draft else { return }
        let preset = Providers.find(d.provider)
        guard preset != draftPreset else { return }
        func fill(_ current: String, _ old: String?, _ new: String?) -> String {
            let t = current.trimmed
            return t.isEmpty || t == old ? (new ?? "") : current
        }
        d.baseUrl = fill(d.baseUrl, draftPreset?.baseUrl, preset?.baseUrl)
        d.envVar = fill(d.envVar, draftPreset?.envVar, preset?.envVar)
        d.consoleUrl = fill(d.consoleUrl, draftPreset?.consoleUrl, preset?.consoleUrl)
        draftPreset = preset
        draft = d
    }

    func draftKeyChanged() {
        guard let d = draft, d.provider.trimmed.isEmpty, let guess = Providers.guess(fromKey: d.key) else { return }
        draft?.provider = guess.name
        draftProviderChanged()
        keyGuessHint = "根据 Key 的前缀认出是 \(guess.name)，已自动填好服务商和常用地址"
    }

    func validate(_ d: ApiEntry) -> String? {
        let key = d.key.trimmed
        if key.isEmpty { return "API Key 不能为空。" }
        if key.contains(where: { $0.isWhitespace }) { return "Key 中间有空格或换行，请检查是不是粘贴完整了。" }
        if !d.baseUrl.trimmed.isEmpty && !Self.isWebURL(d.baseUrl) { return "Base URL 要以 http:// 或 https:// 开头。" }
        if !d.consoleUrl.trimmed.isEmpty && !Self.isWebURL(d.consoleUrl) { return "控制台网址要以 http:// 或 https:// 开头。" }
        if !d.envVar.trimmed.isEmpty && !Snippets.isValidName(d.envVar.trimmed) {
            return "环境变量名只能包含英文字母、数字和下划线，且不能以数字开头。"
        }
        if let twin = entries.first(where: { $0.id != editingID && $0.key.trimmed == key }) {
            return "这个 Key 已经保存在「\(twin.displayName)」里了。"
        }
        return nil
    }

    func saveDraft() {
        guard var d = draft, isUnlocked else { return }
        if let error = validate(d) { editError = error; return }
        if d.name.trimmed.isEmpty { d.name = d.displayName }
        let isNew = editingID == nil
        let saved: ApiEntry
        if let id = editingID, let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].copyFields(from: d)
            entries[i].updated = Date()
            saved = entries[i]
        } else {
            var fresh = ApiEntry()
            fresh.copyFields(from: d)
            entries.append(fresh)
            saved = fresh
        }
        persist()
        cancelEdit()
        if !filtered.contains(where: { $0.id == saved.id }) { search = "" }
        selection = saved.id
        showToast((isNew ? "已保存「" : "已更新「") + saved.displayName + "」")
    }

    static func isWebURL(_ s: String) -> Bool {
        guard let u = URL(string: s.trimmed), let scheme = u.scheme?.lowercased(), u.host != nil else { return false }
        return scheme == "https" || scheme == "http"
    }

    // MARK: import / settings

    func openImport() {
        guard isUnlocked, draft == nil else { return }
        importRequest = ImportRequest(candidates: EnvScanner.scan(home: homeDir, environment: ProcessInfo.processInfo.environment, stored: entries))
    }

    func importSelected(_ list: [EnvCandidate]) {
        importRequest = nil
        guard isUnlocked, !list.isEmpty else { return }
        let added = list.map(EnvScanner.toEntry)
        entries.append(contentsOf: added)
        persist()
        search = ""
        selection = added.first?.id
        showToast("已导入 \(added.count) 个 Key")
    }

    /// Turns Touch ID unlock on or off; returns an error message, or nil.
    func setQuickUnlock(_ on: Bool) -> String? {
        guard let v = vault else { return "先解锁密钥匣" }
        if on {
            do { try KeychainUnlock.store(v, paths: paths) } catch { return "存进钥匙串失败：" + error.localizedDescription }
        } else {
            KeychainUnlock.remove(paths)
        }
        settings.quickUnlock = on
        return nil
    }

    func changePassword(current: String, new: String, again: String) async -> (message: String, ok: Bool) {
        guard let v = vault else { return ("先解锁密钥匣", false) }
        if new.count < 8 { return ("新主密码至少 8 位。", false) }
        if new != again { return ("两次输入的新主密码不一样。", false) }
        if new == current { return ("新主密码和当前的一样。", false) }
        let pending = await Task.detached { v.checkPassword(current) ? Vault.prepareKey(new) : nil }.value
        guard let pending else { return ("当前主密码不对。", false) }
        guard v.isOpen else { return ("密钥匣已锁定。", false) }
        do {
            try v.rekey(pending)
            if settings.quickUnlock { try? KeychainUnlock.store(v, paths: paths) }
            return ("主密码已修改。下次解锁请用新密码。", true)
        } catch {
            return ("保存失败：" + error.localizedDescription, false)
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
