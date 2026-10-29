using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using KeyBox.Core;

namespace KeyBox;

public partial class App : Application
{
    Mutex? instanceMutex;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var paths = DataPaths.FromArgs(e.Args);

        // One window per vault: two instances saving the same file would overwrite each other.
        var id = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(paths.Dir.ToUpperInvariant())))[..16];
        instanceMutex = new Mutex(true, @"Local\KeyBox-" + id, out bool first);
        if (!first)
        {
            ActivateOtherInstance();
            Shutdown();
            return;
        }

        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show(args.Exception.Message, "密钥匣出错了", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };

        MainWindow = new MainWindow(paths);
        MainWindow.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        instanceMutex?.Dispose();
        base.OnExit(e);
    }

    static void ActivateOtherInstance()
    {
        var self = Process.GetCurrentProcess();
        foreach (var p in Process.GetProcessesByName(self.ProcessName))
        {
            if (p.Id == self.Id || p.MainWindowHandle == IntPtr.Zero) continue;
            ShowWindow(p.MainWindowHandle, 9 /* SW_RESTORE */);
            SetForegroundWindow(p.MainWindowHandle);
            return;
        }
    }

    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
}
