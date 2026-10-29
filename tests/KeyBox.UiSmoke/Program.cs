using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Automation;
using WinClipboard = System.Windows.Forms.Clipboard;

namespace KeyBox.UiSmoke;

/// <summary>
/// End-to-end smoke test: starts KeyBox.exe on a throwaway data folder, drives it through
/// UI Automation (create vault, add, copy, search, lock, delete, restart, idle lock) and
/// saves screenshots of each screen.
/// </summary>
static class Program
{
    static readonly List<string> Failures = [];
    static string shotDir = "";

    [STAThread]
    static int Main(string[] args)
    {
        SetProcessDpiAwarenessContext(-4); // per-monitor v2, so screenshots are at real pixels
        var exe = Path.GetFullPath(args.Length > 0 ? args[0] : @"..\..\dist\KeyBox.exe");
        shotDir = Path.GetFullPath(args.Length > 1 ? args[1] : "shots");
        bool skipIdle = args.Contains("--skip-idle");
        Directory.CreateDirectory(shotDir);

        var data = Path.Combine(Path.GetTempPath(), "keybox-ui-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(data);
        File.WriteAllText(Path.Combine(data, "settings.json"), """{"autoLockMinutes":1,"clipboardSeconds":3}""");
        const string password = "test-password-123";
        const string claudeKey = "sk-ant-api03-FAKEkeyForUiTest000000000000000abcd";
        const string deepseekKey = "sk-0123456789abcdef0123456789abcd";

        var app = Launch(exe, data);
        try
        {
            var w = MainWindow(app);
            Check("first run shows the create screen", Find(w, "ConfirmBox") is not null);
            Shot(w, "01-create");

            Set(w, "MasterBox", "short");
            Set(w, "ConfirmBox", "short");
            Invoke(w, "UnlockButton");
            Check("too-short master password is refused", WaitText(w, "LockError", t => t.Contains("至少 8 位")));

            Set(w, "MasterBox", password);
            Set(w, "ConfirmBox", password);
            Invoke(w, "UnlockButton");
            Check("vault is created and opened", Find(w, "AddButton", 15000) is not null);
            Check("vault.json written", File.Exists(Path.Combine(data, "vault.json")));
            Shot(w, "02-empty");

            Invoke(w, "AddButton");
            Set(w, "KeyInput", claudeKey);
            Thread.Sleep(400);
            Check("provider guessed from sk-ant- prefix", Value(w, "ProviderBox") == "Anthropic");
            Shot(w, "03-edit");
            Invoke(w, "SaveButton");
            Check("detail shows the key masked", WaitValue(w, "KeyText", v => v.StartsWith("sk-a") && v.Contains('•') && v.EndsWith("abcd")));
            Shot(w, "04-detail");

            Invoke(w, "AddButton");
            Set(w, "ProviderBox", "DeepSeek");
            Set(w, "KeyInput", deepseekKey);
            Set(w, "NameInput", "DeepSeek 主账号");
            Invoke(w, "SaveButton");
            Check("two entries listed", WaitText(w, "CountText", t => t == "2 个"));
            Check("preset filled the env var (env card shown)", Find(w, "WriteEnvButton") is not null);
            Shot(w, "05-deepseek");

            Invoke(w, "RevealButton");
            Check("reveal shows the full key", WaitValue(w, "KeyText", v => v == deepseekKey));
            Invoke(w, "RevealButton");

            Invoke(w, "CopyKeyButton");
            Thread.Sleep(500);
            Check("copy puts the key on the clipboard", WinClipboard.ContainsText() && WinClipboard.GetText() == deepseekKey);
            var formats = WinClipboard.GetDataObject()?.GetFormats() ?? [];
            Check("copy opts out of clipboard history", formats.Contains("CanIncludeInClipboardHistory") && formats.Contains("ExcludeClipboardContentFromMonitorProcessing"));
            Check("toast confirms the copy", WaitText(w, "ToastText", t => t.Contains("已复制")));
            Thread.Sleep(4000);
            Check("clipboard cleared after 3 s", !WinClipboard.ContainsText() || WinClipboard.GetText() != deepseekKey);

            Invoke(w, "AddButton");
            Set(w, "KeyInput", deepseekKey);
            Invoke(w, "SaveButton");
            Check("duplicate key is refused", WaitText(w, "EditError", t => t.Contains("已经保存在")));
            Invoke(w, "CancelButton");

            Set(w, "SearchBox", "deep");
            Check("search filters the list", WaitText(w, "CountText", t => t == "1 / 2"));
            Set(w, "SearchBox", "");

            Invoke(w, "SettingsButton");
            var settings = WaitFor(() => OtherWindow(app, w), 5000);
            Check("settings window opens", settings is not null);
            if (settings is not null)
            {
                Thread.Sleep(400);
                Shot(settings, "06-settings");
                ((WindowPattern)settings.GetCurrentPattern(WindowPattern.Pattern)).Close();
            }

            Invoke(w, "LockButton");
            Check("lock returns to the password screen", Find(w, "MasterBox") is not null && Find(w, "AddButton", 500) is null);
            Shot(w, "07-locked");
            Set(w, "MasterBox", "wrong-password");
            Invoke(w, "UnlockButton");
            Check("wrong password is refused", WaitText(w, "LockError", t => t.Contains("不对"), 8000));
            Set(w, "MasterBox", password);
            Invoke(w, "UnlockButton");
            Check("unlock brings both entries back", WaitText(w, "CountText", t => t == "2 个", 15000));

            Invoke(w, "DeleteButton");
            var box = WaitFor(() => OtherWindow(app, w), 5000);
            Check("delete asks for confirmation", box is not null);
            if (box is not null) Invoke(box, "1"); // IDOK
            Check("entry deleted", WaitText(w, "CountText", t => t == "1 个"));

            app.CloseMainWindow();
            app.WaitForExit(5000);
            app = Launch(exe, data);
            w = MainWindow(app);
            Set(w, "MasterBox", password);
            Invoke(w, "UnlockButton");
            Check("after restart the remaining entry is still there", WaitText(w, "CountText", t => t == "1 个", 15000));

            if (!skipIdle)
            {
                Console.WriteLine("  ..   waiting for the 1-minute idle lock");
                Check("locks itself after 1 idle minute", WaitFor(() => Find(w, "AddButton", 200) is null ? w : null, 90_000) is not null);
            }
        }
        catch (Exception ex)
        {
            Failures.Add("crashed: " + ex);
            Console.WriteLine(ex);
        }
        finally
        {
            if (!app.HasExited) app.Kill();
            Directory.Delete(data, recursive: true);
        }

        Console.WriteLine(Failures.Count == 0 ? "\nUI 冒烟测试全部通过" : $"\n{Failures.Count} 项失败：\n  " + string.Join("\n  ", Failures));
        Console.WriteLine("截图：" + shotDir);
        return Failures.Count == 0 ? 0 : 1;
    }

    static Process Launch(string exe, string data) =>
        Process.Start(new ProcessStartInfo(exe, $"--data \"{data}\"") { UseShellExecute = false })!;

    static void Check(string name, bool ok)
    {
        Console.WriteLine((ok ? "  ok   " : "  FAIL ") + name);
        if (!ok) Failures.Add(name);
    }

    static T? WaitFor<T>(Func<T?> probe, int timeoutMs) where T : class
    {
        var sw = Stopwatch.StartNew();
        do
        {
            try { if (probe() is { } hit) return hit; } catch (ElementNotAvailableException) { }
            Thread.Sleep(100);
        } while (sw.ElapsedMilliseconds < timeoutMs);
        return null;
    }

    static AutomationElement MainWindow(Process p) =>
        WaitFor(() => AutomationElement.RootElement.FindFirst(TreeScope.Children,
            new PropertyCondition(AutomationElement.ProcessIdProperty, p.Id)), 15000)
        ?? throw new TimeoutException("KeyBox window did not appear");

    static AutomationElement? OtherWindow(Process p, AutomationElement main)
    {
        var all = AutomationElement.RootElement.FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ProcessIdProperty, p.Id));
        foreach (AutomationElement el in all)
            if (!Automation.Compare(el, main)) return el;
        // owned dialogs can also appear as children of the main window
        return main.FindFirst(TreeScope.Children, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
    }

    static AutomationElement? Find(AutomationElement root, string id, int timeoutMs = 5000) =>
        WaitFor(() =>
        {
            var el = root.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, id));
            return el is not null && !el.Current.IsOffscreen ? el : null;
        }, timeoutMs);

    static AutomationElement Must(AutomationElement root, string id) =>
        Find(root, id) ?? throw new InvalidOperationException("element not found: " + id);

    static void Set(AutomationElement root, string id, string value) =>
        ((ValuePattern)Must(root, id).GetCurrentPattern(ValuePattern.Pattern)).SetValue(value);

    static string Value(AutomationElement root, string id) =>
        ((ValuePattern)Must(root, id).GetCurrentPattern(ValuePattern.Pattern)).Current.Value;

    static void Invoke(AutomationElement root, string id)
    {
        ((InvokePattern)Must(root, id).GetCurrentPattern(InvokePattern.Pattern)).Invoke();
        Thread.Sleep(250);
    }

    static bool WaitText(AutomationElement root, string id, Func<string, bool> ok, int timeoutMs = 5000) =>
        WaitFor(() => Find(root, id, 200) is { } el && ok(el.Current.Name) ? el : null, timeoutMs) is not null;

    static bool WaitValue(AutomationElement root, string id, Func<string, bool> ok, int timeoutMs = 5000) =>
        WaitFor(() => Find(root, id, 200) is { } el && ok(((ValuePattern)el.GetCurrentPattern(ValuePattern.Pattern)).Current.Value) ? el : null, timeoutMs) is not null;

    static void Shot(AutomationElement window, string name)
    {
        Thread.Sleep(350); // let animations settle
        var hwnd = new IntPtr(window.Current.NativeWindowHandle);
        GetWindowRect(hwnd, out var r);
        using var bmp = new Bitmap(r.Right - r.Left, r.Bottom - r.Top, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            var hdc = g.GetHdc();
            PrintWindow(hwnd, hdc, 2 /* PW_RENDERFULLCONTENT */);
            g.ReleaseHdc(hdc);
        }
        bmp.Save(Path.Combine(shotDir, name + ".png"), ImageFormat.Png);
    }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(nint value);
}
