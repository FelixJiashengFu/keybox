using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using KeyBox.Core;

namespace KeyBox;

public partial class SettingsWindow : Window
{
    readonly DataPaths paths;
    readonly AppSettings settings;
    readonly Vault vault;
    bool loading = true;

    public SettingsWindow(DataPaths paths, AppSettings settings, Vault vault)
    {
        InitializeComponent();
        this.paths = paths;
        this.settings = settings;
        this.vault = vault;

        SelectByTag(AutoLockBox, settings.AutoLockMinutes, " 分钟");
        SelectByTag(ClipboardBox, settings.ClipboardSeconds, " 秒");
        QuickUnlockCheck.IsChecked = DeviceUnlock.IsEnabled(paths);
        DataPathText.Text = paths.Dir;
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3);
        AboutText.Text = $"密钥匣 KeyBox {version}\n"
            + $"加密：AES-256-GCM，密钥由主密码经 PBKDF2-HMAC-SHA256（{Vault.DefaultIterations:N0} 次迭代）派生。\n"
            + "所有数据只存在这台电脑上；只有点「测试这个 Key」时才会联网，而且只连那个服务商。";
        loading = false;
    }

    // A value edited by hand in settings.json that is not in the list gets its own item.
    static void SelectByTag(ComboBox box, int value, string unit)
    {
        var match = box.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == value.ToString());
        if (match is null)
        {
            match = new ComboBoxItem { Content = value + unit, Tag = value.ToString() };
            box.Items.Add(match);
        }
        box.SelectedItem = match;
    }

    static int TagOf(ComboBox box) => int.Parse((string)((ComboBoxItem)box.SelectedItem).Tag);

    void AutoLockChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading) return;
        settings.AutoLockMinutes = TagOf(AutoLockBox);
        settings.Save(paths.Settings);
    }

    void ClipboardChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading) return;
        settings.ClipboardSeconds = TagOf(ClipboardBox);
        settings.Save(paths.Settings);
    }

    void QuickUnlockChanged(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        if (QuickUnlockCheck.IsChecked == true) DeviceUnlock.Enable(paths, vault);
        else DeviceUnlock.Disable(paths);
    }

    async void ChangePasswordClick(object sender, RoutedEventArgs e)
    {
        var current = CurrentBox.Password;
        var next = NewBox.Password;
        if (next.Length < 8) { Status("新主密码至少 8 位。", false); return; }
        if (next != RepeatBox.Password) { Status("两次输入的新主密码不一样。", false); return; }
        if (next == current) { Status("新主密码和当前的一样。", false); return; }

        ChangeButton.IsEnabled = false;
        Status("正在修改…", null);
        try
        {
            var pending = await Task.Run<Vault.PendingKey?>(() => vault.CheckPassword(current) ? Vault.PrepareKey(next) : null);
            if (pending is null) { Status("当前主密码不对。", false); return; }
            if (!vault.IsOpen) return; // locked meanwhile
            vault.Rekey(pending);
            if (DeviceUnlock.IsEnabled(paths)) DeviceUnlock.Enable(paths, vault);
            CurrentBox.Clear();
            NewBox.Clear();
            RepeatBox.Clear();
            Status("主密码已修改。下次解锁请用新密码。", true);
        }
        catch (IOException ex)
        {
            Status("保存失败：" + ex.Message, false);
        }
        finally
        {
            ChangeButton.IsEnabled = true;
        }
    }

    void Status(string text, bool? ok)
    {
        ChangeStatus.Text = text;
        ChangeStatus.SetResourceReference(ForegroundProperty, ok switch
        {
            true => "SystemFillColorSuccessBrush",
            false => "SystemFillColorCriticalBrush",
            null => "TextFillColorSecondaryBrush",
        });
    }

    void OpenFolderClick(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{paths.Dir}\"") { UseShellExecute = true });
}
