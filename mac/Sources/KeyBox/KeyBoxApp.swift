import AppKit
import KeyBoxCore
import SwiftUI

@main
struct KeyBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = VaultModel(paths: DataPaths.fromArguments(CommandLine.arguments))

    var body: some Scene {
        Window("密钥匣", id: "main") {
            RootView()
                .environmentObject(model)
                .onAppear { delegate.attach(model) }
        }
        .defaultSize(width: 1060, height: 700)
        .commands { KeyBoxCommands(model: model) }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: VaultModel?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        SecureClipboard.clearIfOurs()
        model?.lock()
    }

    func attach(_ model: VaultModel) {
        guard self.model == nil else { return }
        self.model = model

        // Idle timer: only real input to this app counts as activity.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak model] event in
            model?.noteActivity()
            return event
        }
        let lockOn: (Notification.Name, NotificationCenter, String) -> NSObjectProtocol = { name, center, reason in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak model] _ in
                guard let model else { return }
                Task { @MainActor in model.lock(reason) }
            }
        }
        observers.append(lockOn(Notification.Name("com.apple.screenIsLocked"), DistributedNotificationCenter.default(), "屏幕锁定时已自动锁定"))
        observers.append(lockOn(NSWorkspace.willSleepNotification, NSWorkspace.shared.notificationCenter, "电脑睡眠时已自动锁定"))
        observers.append(lockOn(NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.shared.notificationCenter, "切换用户时已自动锁定"))

        #if DEBUG
        if let dir = DataPaths.argument("--ui-snapshot", in: CommandLine.arguments) {
            SnapshotRun.start(model: model, outputDir: URL(fileURLWithPath: dir))
        }
        #endif
    }
}

struct KeyBoxCommands: Commands {
    @ObservedObject var model: VaultModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新增 API Key") { model.beginAdd() }
                .keyboardShortcut("n")
                .disabled(!model.isUnlocked || model.draft != nil)
            Button("从环境变量导入…") { model.openImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!model.isUnlocked || model.draft != nil)
        }
        CommandMenu("密钥") {
            Button("复制 API Key") { if let e = model.selected { model.copyKey(e) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.selected == nil || model.draft != nil)
            Button("编辑") { if let e = model.selected { model.beginEdit(e) } }
                .keyboardShortcut("e")
                .disabled(model.selected == nil || model.draft != nil)
            Divider()
            Button("立即锁定") { model.lock() }
                .keyboardShortcut("l")
                .disabled(!model.isUnlocked)
        }
    }
}
