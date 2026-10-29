import KeyBoxCore
import SwiftUI

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

let monoFont = Font.system(.body, design: .monospaced)

struct Avatar: View {
    let entry: ApiEntry
    var size: CGFloat = 30

    var body: some View {
        Circle()
            .fill(Color(hex: entry.color))
            .overlay(Text(entry.initial).font(.system(size: size * 0.44, weight: .semibold)).foregroundColor(.white))
            .frame(width: size, height: size)
    }
}

/// A rounded box with a small caption, like the cards in the Windows version.
struct Card<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A caption above a form control.
struct Field<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            Text(text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

/// A text field with a menu of the preset providers (SwiftUI on macOS has no editable combo box).
struct ProviderField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text).textFieldStyle(.roundedBorder)
            Menu {
                ForEach(Providers.all, id: \.name) { p in
                    Button(p.name) { text = p.name }
                }
                Divider()
                Button("自定义（清空）") { text = "" }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("选一个常用服务商")
        }
    }
}
