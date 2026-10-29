import AppKit

/// Copies secrets marked as concealed/transient (the nspasteboard.org convention that clipboard managers
/// honour, so they neither show nor keep them), and clears the clipboard again after a delay if it still
/// holds what we put there.
@MainActor
enum SecureClipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private static var ourChangeCount: Int?
    private static var clearTask: Task<Void, Never>?

    static func copySecret(_ text: String, clearAfter seconds: Int) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: concealed)
        pb.setData(Data(), forType: transient)
        ourChangeCount = pb.changeCount
        clearTask?.cancel()
        guard seconds > 0 else { return }
        clearTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            if !Task.isCancelled { clearIfOurs() }
        }
    }

    /// Ordinary copy for things that are not secret (a Base URL).
    static func copyPlain(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ourChangeCount = nil
    }

    /// Clears the clipboard only if nobody has copied anything else since our last secret.
    static func clearIfOurs() {
        clearTask?.cancel()
        if let count = ourChangeCount, NSPasteboard.general.changeCount == count {
            NSPasteboard.general.clearContents()
        }
        ourChangeCount = nil
    }
}
