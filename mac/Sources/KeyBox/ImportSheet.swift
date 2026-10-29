import KeyBoxCore
import SwiftUI

struct ImportSheet: View {
    @EnvironmentObject var model: VaultModel
    @State private var rows: [Row]

    struct Row: Identifiable {
        let candidate: EnvCandidate
        var checked: Bool
        var id: String { candidate.id }
    }

    init(candidates: [EnvCandidate]) {
        _rows = State(initialValue: candidates.map { Row(candidate: $0, checked: !$0.alreadyStored) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从环境变量导入").font(.title2).fontWeight(.semibold)
            Text("下面是 ~/.zshrc、~/.zprofile 等 shell 配置文件和当前环境里看起来像 Key 的变量（变量名里有 KEY、TOKEN、SECRET 等）。勾选要收进密钥匣的；那些文件本身不会被改动。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if rows.isEmpty {
                Text("没找到像 Key 的变量。可以关掉这个窗口，点「新增」手动粘贴。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($rows) { $row in
                        Toggle(isOn: $row.checked) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.candidate.name).font(monoFont).fontWeight(.semibold)
                                Text(ApiEntry.mask(row.candidate.value)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                Text(note(row.candidate)).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .disabled(row.candidate.alreadyStored)
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }

            HStack {
                Spacer()
                Button("取消") { model.importRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("导入所选") {
                    model.importSelected(rows.filter { $0.checked && !$0.candidate.alreadyStored }.map(\.candidate))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!rows.contains { $0.checked && !$0.candidate.alreadyStored })
            }
        }
        .padding(22)
        .frame(width: 580, height: 500)
    }

    private func note(_ c: EnvCandidate) -> String {
        let source = "来自 " + c.source
        if c.alreadyStored { return source + " · 已经在密钥匣里了" }
        if let p = c.guess { return source + " · 识别为 " + p.name }
        return source + " · 未识别服务商，导入后可以再编辑"
    }
}
