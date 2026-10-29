import KeyBoxCore
import SwiftUI

struct DetailView: View {
    @EnvironmentObject var model: VaultModel
    let entry: ApiEntry
    @State private var confirmDelete = false
    @State private var confirmZshrc = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                Card("API KEY") {
                    HStack(spacing: 10) {
                        Text(model.revealed ? entry.key : entry.maskedKey)
                            .font(.system(size: 14, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.toggleReveal() } label: {
                            Image(systemName: model.revealed ? "eye.slash" : "eye")
                        }
                        .help(model.revealed ? "隐藏" : "显示 30 秒")
                        Button { model.copyKey(entry) } label: { Label("复制", systemImage: "doc.on.doc") }
                            .buttonStyle(.borderedProminent)
                            .help("复制 Key（⇧⌘C）")
                    }
                }

                if !entry.baseUrl.isEmpty {
                    Card("BASE URL") {
                        HStack {
                            Text(entry.baseUrl).font(monoFont).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { model.copyPlain(entry.baseUrl, " Base URL") } label: { Label("复制", systemImage: "doc.on.doc") }
                        }
                    }
                }

                if !entry.envVar.isEmpty {
                    Card("环境变量") {
                        Text(entry.envVar).font(monoFont).textSelection(.enabled)
                        HStack {
                            Button { model.copyExport(entry) } label: { Label("复制 export 行", systemImage: "terminal") }
                            Button { model.copyDotEnv(entry) } label: { Label("复制 .env 行", systemImage: "doc.plaintext") }
                            Button { confirmZshrc = true } label: { Label("写入 ~/.zshrc", systemImage: "square.and.pencil") }
                                .disabled(!Snippets.isValidName(entry.envVar))
                        }
                        .padding(.top, 4)
                        Text(model.zshrcStatus(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if VaultModel.isWebURL(entry.consoleUrl), let url = URL(string: entry.consoleUrl.trimmed) {
                    Card("控制台") {
                        Link(entry.consoleUrl, destination: url)
                    }
                }

                if !entry.notes.isEmpty {
                    Card("备注") {
                        Text(entry.notes).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card("连接测试") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Button { model.test(entry) } label: { Label("测试这个 Key", systemImage: "bolt") }
                            .disabled(!KeyTester.canTest(entry) || model.testing)
                        if model.testing { ProgressView().controlSize(.small) }
                        testText
                    }
                    Text("只在你点击时，向服务商发一次只读请求（列出模型 / 查询账号），不会产生费用。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Text(meta).font(.caption).foregroundStyle(.tertiary).padding(.leading, 4)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("删除「\(entry.displayName)」？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { model.delete(entry) }
        } message: {
            Text("删除后无法恢复。")
        }
        .alert("写入 ~/.zshrc？", isPresented: $confirmZshrc) {
            Button("写入") { model.writeToZshrc(entry) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会在 ~/.zshrc 里写一行 export \(entry.envVar)=…（已经有就替换），原文件另存为 .zshrc.keybox.bak。注意那是明文文件，你账户下的程序都能读到；新开的终端才会生效。")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Avatar(entry: entry, size: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.system(size: 24, weight: .semibold)).lineLimit(1)
                if !entry.provider.isEmpty && entry.provider != entry.displayName {
                    Text(entry.provider).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.beginEdit(entry) } label: { Label("编辑", systemImage: "pencil") }
            Button { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder private var testText: some View {
        if let r = model.testResult {
            Text((r.ok ? "✓ " : "✗ ") + r.message).foregroundColor(r.ok ? .green : .red)
                .fixedSize(horizontal: false, vertical: true)
        } else if !KeyTester.canTest(entry) {
            Text("这个服务商没有内置测试；填上 OpenAI 兼容的 Base URL 就能测。").foregroundStyle(.secondary)
        }
    }

    private var meta: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let copied = entry.lastCopied.map { f.string(from: $0) } ?? "从未"
        return "创建于 \(f.string(from: entry.created))　·　修改于 \(f.string(from: entry.updated))　·　上次复制 \(copied)"
    }
}

struct EditView: View {
    @EnvironmentObject var model: VaultModel
    @Binding var draft: ApiEntry
    @FocusState private var focus: Focus?

    enum Focus { case key, name }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(model.editingID == nil ? "新增 API Key" : "编辑「\(draft.displayName)」")
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Button("取消") { model.cancelEdit() }
                        .keyboardShortcut(.cancelAction)
                    Button { model.saveDraft() } label: { Label("保存", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s")
                        .help("保存（⌘S）")
                }
                if let error = model.editError {
                    Text(error).foregroundColor(.red).padding(.top, 8)
                }

                Field("API Key（必填）") {
                    TextField("", text: $draft.key)
                        .font(monoFont)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .key)
                }
                if let hint = model.keyGuessHint {
                    Text(hint).font(.caption).foregroundColor(.accentColor).padding(.top, 5)
                }

                HStack(alignment: .top, spacing: 16) {
                    Field("服务商") { ProviderField(text: $draft.provider) }
                    Field("名称（如「DeepSeek 主账号」）") {
                        TextField("", text: $draft.name).textFieldStyle(.roundedBorder).focused($focus, equals: .name)
                    }
                }

                Field("Base URL（可选）") {
                    TextField("", text: $draft.baseUrl).font(monoFont).textFieldStyle(.roundedBorder)
                }

                HStack(alignment: .top, spacing: 16) {
                    Field("环境变量名（可选）") {
                        TextField("", text: $draft.envVar).font(monoFont).textFieldStyle(.roundedBorder)
                    }
                    Field("控制台网址（可选）") {
                        TextField("", text: $draft.consoleUrl).textFieldStyle(.roundedBorder)
                    }
                }

                Field("备注（账号、额度、用在哪个项目…）") {
                    TextEditor(text: $draft.notes)
                        .font(.body)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: draft.key) { _ in model.draftKeyChanged() }
        .onChange(of: draft.provider) { _ in model.draftProviderChanged() }
        .onAppear { focus = model.editingID == nil ? .key : .name }
    }
}
