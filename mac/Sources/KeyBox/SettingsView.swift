import AppKit
import KeyBoxCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: VaultModel
    @State private var current = ""
    @State private var newPassword = ""
    @State private var again = ""
    @State private var status: (message: String, ok: Bool)?
    @State private var working = false
    @State private var quickUnlockError: String?

    var body: some View {
        Form {
            Section("安全") {
                Picker("空闲多久自动锁定", selection: $model.settings.autoLockMinutes) {
                    Text("1 分钟").tag(1)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("30 分钟").tag(30)
                    Text("1 小时").tag(60)
                    Text("从不").tag(0)
                }
                Picker("复制后多久清除剪贴板", selection: $model.settings.clipboardSeconds) {
                    Text("15 秒").tag(15)
                    Text("30 秒").tag(30)
                    Text("1 分钟").tag(60)
                    Text("2 分钟").tag(120)
                    Text("不清除").tag(0)
                }
                Text("复制的 Key 会标记为「隐藏内容」，剪贴板管理工具不会显示或记录它。屏幕锁定、电脑睡眠时密钥匣也会一起锁上。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("用 \(model.biometryName) 解锁（不用输入主密码）", isOn: Binding(
                    get: { model.settings.quickUnlock },
                    set: { quickUnlockError = model.setQuickUnlock($0) }))
                    .disabled(!model.isUnlocked)
                Text(quickUnlockError ?? "解密钥匙存进你的「钥匙串」，打开密钥匣时先验证 \(model.biometryName)。方便，但以你的账户运行、且被你允许访问这条钥匙串项目的程序也能取到它。")
                    .font(.caption)
                    .foregroundColor(quickUnlockError == nil ? .secondary : .red)
            }

            Section("修改主密码") {
                SecureField("当前主密码", text: $current)
                SecureField("新主密码（至少 8 位）", text: $newPassword)
                SecureField("再输入一次", text: $again)
                HStack {
                    Button(working ? "正在修改…" : "修改主密码") {
                        working = true
                        Task {
                            status = await model.changePassword(current: current, new: newPassword, again: again)
                            working = false
                            if status?.ok == true { current = ""; newPassword = ""; again = "" }
                        }
                    }
                    .disabled(!model.isUnlocked || working)
                    if let s = status {
                        Text(s.message).foregroundColor(s.ok ? .green : .red)
                    } else if !model.isUnlocked {
                        Text("解锁后才能修改").foregroundStyle(.secondary)
                    }
                }
            }

            Section("数据") {
                Text(model.paths.dir.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("vault.json 和 Windows 版密钥匣的格式完全一样：复制过去，用同一个主密码就能打开。vault.json.bak 是上一次保存前的版本。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.vault]) }
            }

            Section("关于") {
                Text(about).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
    }

    private var about: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "密钥匣 KeyBox \(version)\n加密：AES-256-GCM，密钥由主密码经 PBKDF2-HMAC-SHA256（\(Vault.defaultIterations) 次迭代）派生。\n所有数据只存在这台 Mac 上；只有点「测试这个 Key」时才会联网，而且只连那个服务商。"
    }
}
