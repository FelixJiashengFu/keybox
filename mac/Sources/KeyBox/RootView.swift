import KeyBoxCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: VaultModel

    var body: some View {
        Group {
            if model.isUnlocked { MainView() } else { LockView() }
        }
        .frame(minWidth: 820, minHeight: 540)
        .overlay(alignment: .bottom) {
            if let text = model.toast {
                ToastView(text: text)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }
}

struct LockView: View {
    @EnvironmentObject var model: VaultModel
    @State private var password = ""
    @State private var confirm = ""
    @FocusState private var focused: Bool

    private var creating: Bool { model.isCreating }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("密钥匣")
                .font(.system(size: 30, weight: .semibold))
                .padding(.top, 8)
            Text(model.lockMessage ?? (creating ? "第一次使用：先设置一个主密码" : "输入主密码解锁"))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 6) {
                Text("主密码").font(.caption).foregroundStyle(.secondary)
                SecureField("", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused)
                    .onSubmit(submit)
                if creating {
                    Text("再输入一次").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    SecureField("", text: $confirm)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .onSubmit(submit)
                }
                if let error = model.lockError {
                    Text(error).foregroundColor(.red).font(.callout).padding(.top, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: submit) {
                    Text(model.busy ? (creating ? "正在创建…" : "正在解锁…") : (creating ? "创建密钥匣" : "解锁"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy)
                .padding(.top, 14)

                if model.quickUnlockReady {
                    Button {
                        Task { await model.quickUnlock() }
                    } label: {
                        Label("用 \(model.biometryName) 解锁", systemImage: "touchid").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
                if creating {
                    Text("主密码只用来在这台 Mac 上加密你的 Key（AES-256-GCM），不会保存在任何地方。忘记它就再也打不开密钥匣，请记牢。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            }
            .frame(width: 320)
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            focused = true
            // Offer Touch ID right away when the app opens (not again after a manual lock).
            if model.quickUnlockReady && !model.autoQuickUnlockTried {
                model.autoQuickUnlockTried = true
                Task { await model.quickUnlock() }
            }
        }
    }

    private func submit() {
        Task {
            if creating {
                await model.create(password: password, confirm: confirm)
            } else {
                await model.unlock(password: password)
                if !model.isUnlocked { password = "" }
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: VaultModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            if let draft = Binding($model.draft) {
                EditView(draft: draft)
            } else if let entry = model.selected {
                DetailView(entry: entry)
            } else {
                EmptyStateView()
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "搜索名称、服务商、变量名")
        .onSubmit(of: .search) {
            if let e = model.selected { model.copyKey(e) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.beginAdd() } label: { Label("新增", systemImage: "plus") }
                    .help("新增 API Key（⌘N）")
                    .disabled(model.draft != nil)
                Button { model.openImport() } label: { Label("从环境变量导入", systemImage: "square.and.arrow.down") }
                    .help("把 ~/.zshrc 等文件里已有的 Key 收进来（⇧⌘I）")
                    .disabled(model.draft != nil)
                Button { model.lock() } label: { Label("锁定", systemImage: "lock") }
                    .help("立即锁定（⌘L）")
            }
        }
        .sheet(item: $model.importRequest) { request in
            ImportSheet(candidates: request.candidates)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: VaultModel

    var body: some View {
        List(model.filtered, selection: $model.selection) { entry in
            EntryRow(entry: entry).tag(entry.id)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let e = model.entry(id) {
                Button("复制 API Key") { model.copyKey(e) }
                Button("编辑") { model.beginEdit(e) }
                Divider()
                Button("删除", role: .destructive) { model.delete(e) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let e = model.entry(id) { model.copyKey(e) }
        }
        .disabled(model.draft != nil)
        .overlay {
            if model.filtered.isEmpty {
                Text(model.entries.isEmpty ? "保存的 Key 会列在这里" : "没有匹配的 Key")
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text(model.entries.isEmpty ? "" : "\(model.entries.count) 个 Key · 双击复制")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
        }
    }
}

struct EntryRow: View {
    let entry: ApiEntry

    var body: some View {
        HStack(spacing: 10) {
            Avatar(entry: entry, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName).fontWeight(.semibold).lineLimit(1)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: VaultModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "key")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text(model.entries.isEmpty ? "还没有保存任何 API Key" : "没有选中的 Key")
                .font(.title3).fontWeight(.semibold)
            Text(model.entries.isEmpty
                 ? "点「新增」粘贴一个 Key，或者从 ~/.zshrc 等文件导入已经设置过的 Key。"
                 : "在左边选一个，或者换个搜索词。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if model.entries.isEmpty {
                HStack {
                    Button { model.beginAdd() } label: { Label("新增", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                    Button { model.openImport() } label: { Label("从环境变量导入", systemImage: "square.and.arrow.down") }
                }
                .controlSize(.large)
                .padding(.top, 6)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
