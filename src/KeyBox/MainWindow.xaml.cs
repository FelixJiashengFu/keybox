using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Threading;
using KeyBox.Core;
using Microsoft.Win32;

namespace KeyBox;

public partial class MainWindow : Window
{
    readonly DataPaths paths;
    readonly AppSettings settings;
    Vault? vault;

    readonly ObservableCollection<ApiEntry> entries = [];
    readonly ListCollectionView view;

    ApiEntry? editing;          // the stored entry being edited; null while adding a new one
    ApiEntry? draft;            // what the edit form is bound to
    ProviderPreset? draftPreset;

    bool keyRevealed;
    int failedAttempts;
    DateTime lastActivity = DateTime.Now;
    CursorPoint lastCursor;
    CancellationTokenSource? testCts;

    readonly DispatcherTimer idleTimer = new() { Interval = TimeSpan.FromSeconds(10) };
    readonly DispatcherTimer toastTimer = new() { Interval = TimeSpan.FromSeconds(3.5) };
    readonly DispatcherTimer revealTimer = new() { Interval = TimeSpan.FromSeconds(30) };

    public MainWindow(DataPaths paths)
    {
        InitializeComponent();
        this.paths = paths;
        settings = AppSettings.Load(paths.Settings);

        view = (ListCollectionView)CollectionViewSource.GetDefaultView(entries);
        view.Filter = o => ((ApiEntry)o).Matches(SearchBox.Text);
        view.Culture = CultureInfo.GetCultureInfo("zh-CN");
        view.SortDescriptions.Add(new SortDescription(nameof(ApiEntry.DisplayName), ListSortDirection.Ascending));
        EntryList.ItemsSource = view;
        ProviderBox.ItemsSource = Providers.All.Select(p => p.Name).ToList();

        InputManager.Current.PreProcessInput += OnAnyInput;
        SystemEvents.SessionSwitch += OnSessionSwitch;
        idleTimer.Tick += (_, _) => CheckIdle();
        idleTimer.Start();
        toastTimer.Tick += (_, _) => { toastTimer.Stop(); Toast.Visibility = Visibility.Collapsed; };
        revealTimer.Tick += (_, _) => { revealTimer.Stop(); keyRevealed = false; UpdateKeyText(); };
        PreviewKeyDown += OnShortcut;
        Loaded += (_, _) =>
        {
            ShowLockScreen();
            if (!IsCreating && DeviceUnlock.IsEnabled(paths)) QuickUnlock();
        };
        Closed += OnClosed;
    }

    ApiEntry? Current => DetailView.DataContext as ApiEntry;
    bool IsCreating => !Vault.Exists(paths.Vault);

    // ───────────────────────── lock / unlock ─────────────────────────

    void ShowLockScreen(string? message = null)
    {
        VaultView.Visibility = Visibility.Collapsed;
        LockView.Visibility = Visibility.Visible;
        MasterBox.Clear();
        ConfirmBox.Clear();
        bool creating = IsCreating;
        ConfirmPanel.Visibility = CreateHint.Visibility = creating ? Visibility.Visible : Visibility.Collapsed;
        LockSubtitle.Text = message ?? (creating ? "第一次使用：先设置一个主密码" : "输入主密码解锁");
        UnlockButton.Content = creating ? "创建密钥匣" : "解锁";
        QuickUnlockButton.Visibility = !creating && DeviceUnlock.IsEnabled(paths) ? Visibility.Visible : Visibility.Collapsed;
        LockError.Visibility = Visibility.Collapsed;
        Dispatcher.BeginInvoke(() => MasterBox.Focus(), DispatcherPriority.Input);
    }

    void ShowLockError(string text)
    {
        LockError.Text = text;
        LockError.Visibility = Visibility.Visible;
    }

    void PasswordKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        if (sender == MasterBox && ConfirmPanel.Visibility == Visibility.Visible && ConfirmBox.Password.Length == 0)
            ConfirmBox.Focus();
        else
            UnlockClick(sender, e);
    }

    async void UnlockClick(object sender, RoutedEventArgs e)
    {
        if (!UnlockButton.IsEnabled) return;
        var password = MasterBox.Password;
        bool creating = IsCreating;
        if (creating)
        {
            if (password.Length < 8) { ShowLockError("主密码至少 8 位。可以用一句只有你知道的话。"); return; }
            if (password != ConfirmBox.Password) { ShowLockError("两次输入的主密码不一样。"); return; }
        }
        else if (password.Length == 0) { ShowLockError("请输入主密码。"); return; }

        UnlockButton.IsEnabled = QuickUnlockButton.IsEnabled = false;
        UnlockButton.Content = creating ? "正在创建…" : "正在解锁…";
        LockError.Visibility = Visibility.Collapsed;
        try
        {
            var opened = await Task.Run(() => creating ? Vault.Create(paths.Vault, password) : Vault.Open(paths.Vault, password));
            failedAttempts = 0;
            OnUnlocked(opened);
            if (creating) ShowToast("密钥匣已创建，开始添加你的第一个 Key 吧");
        }
        catch (WrongPasswordException)
        {
            failedAttempts++;
            await Task.Delay(Math.Min(failedAttempts, 6) * 300); // slow down guessing
            ShowLockError("主密码不对，再试一次。");
            MasterBox.SelectAll();
            MasterBox.Focus();
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or JsonException or FormatException or UnauthorizedAccessException)
        {
            ShowLockError("打不开密钥库文件：" + ex.Message);
        }
        finally
        {
            UnlockButton.IsEnabled = QuickUnlockButton.IsEnabled = true;
            UnlockButton.Content = IsCreating ? "创建密钥匣" : "解锁";
        }
    }

    void QuickUnlockClick(object sender, RoutedEventArgs e) => QuickUnlock();

    void QuickUnlock()
    {
        var opened = DeviceUnlock.TryOpen(paths);
        if (opened is null)
        {
            QuickUnlockButton.Visibility = Visibility.Collapsed;
            ShowLockError("本机免密解锁已失效（主密码可能改过），请输入主密码。");
            return;
        }
        OnUnlocked(opened);
    }

    void OnUnlocked(Vault opened)
    {
        vault = opened;
        MasterBox.Clear();
        ConfirmBox.Clear();
        entries.Clear();
        foreach (var entry in opened.Data.Entries) entries.Add(entry);
        SearchBox.Text = "";
        LockView.Visibility = Visibility.Collapsed;
        VaultView.Visibility = Visibility.Visible;
        lastActivity = DateTime.Now;
        RefreshList();
        if (view.Count > 0) EntryList.SelectedIndex = 0;
        else ShowEmpty();
        SearchBox.Focus();
    }

    void Lock(string? reason = null)
    {
        if (vault is null) return;
        CancelTest();
        foreach (var w in OwnedWindows.Cast<Window>().ToList()) w.Close();
        SecureClipboard.ClearIfOurs();
        if (draft is not null) EndEdit();
        vault.Close();
        vault = null;
        entries.Clear();
        DetailView.DataContext = null;
        KeyText.Text = "";
        keyRevealed = false;
        revealTimer.Stop();
        Toast.Visibility = Visibility.Collapsed;
        ShowLockScreen(reason);
    }

    void LockClick(object sender, RoutedEventArgs e) => Lock();

    // Only real input counts as activity: WPF also raises synthetic mouse moves (e.g. after a
    // layout change under a resting cursor), which would otherwise keep the vault unlocked forever.
    void OnAnyInput(object sender, PreProcessInputEventArgs e)
    {
        switch (e.StagingItem.Input)
        {
            case KeyEventArgs or MouseButtonEventArgs or MouseWheelEventArgs or TouchEventArgs or StylusDownEventArgs:
                lastActivity = DateTime.Now;
                break;
            case MouseEventArgs when GetCursorPos(out var p) && p != lastCursor:
                lastCursor = p;
                lastActivity = DateTime.Now;
                break;
        }
    }

    [StructLayout(LayoutKind.Sequential)] record struct CursorPoint(int X, int Y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out CursorPoint point);

    void CheckIdle()
    {
        if (vault is null || settings.AutoLockMinutes <= 0) return;
        if (DateTime.Now - lastActivity >= TimeSpan.FromMinutes(settings.AutoLockMinutes))
            Lock($"空闲 {settings.AutoLockMinutes} 分钟，已自动锁定");
    }

    void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionLock)
            Dispatcher.BeginInvoke(() => Lock("Windows 锁屏时已自动锁定"));
    }

    void OnClosed(object? sender, EventArgs e)
    {
        SecureClipboard.ClearIfOurs();
        vault?.Close();
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        InputManager.Current.PreProcessInput -= OnAnyInput;
    }

    void OnShortcut(object sender, KeyEventArgs e)
    {
        if (vault is null) return;
        bool ctrl = Keyboard.Modifiers == ModifierKeys.Control;
        if (ctrl && e.Key == Key.L) Lock();
        else if (ctrl && e.Key == Key.F && draft is null) { SearchBox.Focus(); SearchBox.SelectAll(); }
        else if (ctrl && e.Key == Key.N && draft is null) BeginEdit(null);
        else if (ctrl && e.Key == Key.S && draft is not null) SaveEditClick(this, e);
        else if (e.Key == Key.Escape && draft is not null) CancelEditClick(this, e);
        else if (e.Key == Key.Escape && SearchBox.IsKeyboardFocused && SearchBox.Text.Length > 0) SearchBox.Text = "";
        else if (e.Key == Key.Enter && SearchBox.IsKeyboardFocused && EntryList.SelectedItem is ApiEntry hit) CopyKey(hit);
        else if (e.Key == Key.Down && SearchBox.IsKeyboardFocused && view.Count > 0)
        {
            if (EntryList.SelectedIndex < 0) EntryList.SelectedIndex = 0;
            (EntryList.ItemContainerGenerator.ContainerFromIndex(EntryList.SelectedIndex) as ListBoxItem)?.Focus();
        }
        else return;
        e.Handled = true;
    }

    // ───────────────────────── list ─────────────────────────

    void Persist()
    {
        if (vault is null) return;
        vault.Data.Entries = entries.ToList();
        vault.Save();
    }

    void RefreshList()
    {
        view.Refresh();
        CountText.Text = entries.Count == 0 ? "" : view.Count == entries.Count ? $"{entries.Count} 个" : $"{view.Count} / {entries.Count}";
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        ListHint.Text = entries.Count == 0 ? "保存的 Key 会列在这里" : "没有匹配的 Key";
        ListHint.Visibility = view.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void SearchChanged(object sender, TextChangedEventArgs e)
    {
        if (vault is null) return;
        RefreshList();
        if (EntryList.SelectedItem is null && view.Count > 0) EntryList.SelectedIndex = 0;
        else if (EntryList.SelectedItem is null) ShowEmpty();
    }

    void EntrySelected(object sender, SelectionChangedEventArgs e)
    {
        if (draft is not null) return;
        if (EntryList.SelectedItem is ApiEntry entry) ShowDetail(entry);
        else ShowEmpty();
    }

    void Select(ApiEntry entry)
    {
        if (!view.Contains(entry)) SearchBox.Text = "";
        EntryList.SelectedItem = entry;
        EntryList.ScrollIntoView(entry);
        ShowDetail(entry);
    }

    void EntryDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is ApiEntry entry) CopyKey(entry);
    }

    static ApiEntry? MenuTarget(object sender) => (sender as FrameworkElement)?.DataContext as ApiEntry;
    void MenuCopyClick(object sender, RoutedEventArgs e) { if (MenuTarget(sender) is { } x) CopyKey(x); }
    void MenuEditClick(object sender, RoutedEventArgs e) { if (MenuTarget(sender) is { } x) { Select(x); BeginEdit(x); } }
    void MenuDeleteClick(object sender, RoutedEventArgs e) { if (MenuTarget(sender) is { } x) DeleteEntry(x); }

    // ───────────────────────── detail ─────────────────────────

    void ShowEmpty()
    {
        CancelTest();
        DetailView.DataContext = null;
        DetailView.Visibility = EditView.Visibility = Visibility.Collapsed;
        EmptyView.Visibility = Visibility.Visible;
        bool none = entries.Count == 0;
        EmptyTitle.Text = none ? "还没有保存任何 API Key" : "没有选中的 Key";
        EmptyText.Text = none
            ? "点左下角「新增」粘贴一个 Key，或者「从环境变量导入」把电脑里已经设置过的 Key 收进来。"
            : "在左边选一个，或者换个搜索词。";
    }

    void ShowDetail(ApiEntry entry)
    {
        CancelTest();
        keyRevealed = false;
        revealTimer.Stop();
        DetailView.DataContext = entry;
        UpdateKeyText();
        BaseUrlCard.Visibility = Shown(entry.BaseUrl.Length > 0);
        EnvCard.Visibility = Shown(entry.EnvVar.Length > 0);
        ConsoleCard.Visibility = Shown(IsWebUrl(entry.ConsoleUrl));
        NotesCard.Visibility = Shown(entry.Notes.Length > 0);
        EnvStatus.Text = EnvStatusText(entry);
        bool testable = KeyTester.CanTest(entry);
        TestButton.IsEnabled = testable;
        TestResultText.Text = testable ? "" : "这个服务商没有内置测试；填上 OpenAI 兼容的 Base URL 就能测。";
        TestResultText.SetResourceReference(ForegroundProperty, "TextFillColorSecondaryBrush");
        UpdateMeta(entry);
        EmptyView.Visibility = EditView.Visibility = Visibility.Collapsed;
        DetailView.Visibility = Visibility.Visible;
        DetailView.ScrollToTop();
    }

    static Visibility Shown(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    static bool IsWebUrl(string s) =>
        Uri.TryCreate(s.Trim(), UriKind.Absolute, out var u) && (u.Scheme == Uri.UriSchemeHttps || u.Scheme == Uri.UriSchemeHttp);

    void UpdateKeyText()
    {
        if (Current is not { } entry) return;
        KeyText.Text = keyRevealed ? entry.Key : entry.MaskedKey;
        RevealGlyph.Text = keyRevealed ? "" : "";
        RevealButton.ToolTip = keyRevealed ? "隐藏" : "显示 30 秒";
    }

    void UpdateMeta(ApiEntry entry) =>
        MetaText.Text = $"创建于 {entry.Created:yyyy-MM-dd HH:mm}　·　修改于 {entry.Updated:yyyy-MM-dd HH:mm}　·　上次复制 {entry.LastCopiedText}";

    static string EnvStatusText(ApiEntry entry)
    {
        if (!Snippets.IsValidName(entry.EnvVar)) return "变量名不合规（只能用英文字母、数字和下划线）";
        var current = Environment.GetEnvironmentVariable(entry.EnvVar, EnvironmentVariableTarget.User);
        if (current is null) return $"Windows 用户环境变量里还没有 {entry.EnvVar}";
        return current.Trim() == entry.Key ? $"✓ 用户环境变量 {entry.EnvVar} 就是这个 Key" : $"用户环境变量里的 {entry.EnvVar} 是另一个值";
    }

    void RevealClick(object sender, RoutedEventArgs e)
    {
        keyRevealed = !keyRevealed;
        revealTimer.Stop();
        if (keyRevealed) revealTimer.Start();
        UpdateKeyText();
    }

    void CopySecret(ApiEntry entry, string text, string what)
    {
        SecureClipboard.Copy(text, settings.ClipboardSeconds);
        entry.LastCopied = DateTime.Now;
        Persist();
        if (Current == entry) UpdateMeta(entry);
        ShowToast(settings.ClipboardSeconds > 0 ? $"已复制{what}，{settings.ClipboardSeconds} 秒后自动从剪贴板清除" : $"已复制{what}");
    }

    void CopyKey(ApiEntry entry) => CopySecret(entry, entry.Key, "「" + entry.DisplayName + "」的 Key");
    void CopyKeyClick(object sender, RoutedEventArgs e) { if (Current is { } x) CopyKey(x); }
    void CopyPowerShellClick(object sender, RoutedEventArgs e) { if (Current is { } x) CopySecret(x, Snippets.PowerShell(x.EnvVar, x.Key), " PowerShell 命令"); }
    void CopyBashClick(object sender, RoutedEventArgs e) { if (Current is { } x) CopySecret(x, Snippets.Bash(x.EnvVar, x.Key), " Bash 命令"); }
    void CopyDotEnvClick(object sender, RoutedEventArgs e) { if (Current is { } x) CopySecret(x, Snippets.DotEnv(x.EnvVar, x.Key), " .env 行"); }

    void CopyBaseUrlClick(object sender, RoutedEventArgs e)
    {
        if (Current is not { } x) return;
        SecureClipboard.CopyPlain(x.BaseUrl);
        ShowToast("已复制 Base URL");
    }

    async void WriteEnvClick(object sender, RoutedEventArgs e)
    {
        if (Current is not { } entry) return;
        var name = entry.EnvVar;
        var value = entry.Key;
        if (!Snippets.IsValidName(name))
        {
            MessageBox.Show(this, "环境变量名只能包含英文字母、数字和下划线，且不能以数字开头。", "密钥匣", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        var existing = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User);
        var note = existing is null ? "" : existing.Trim() == value ? "它现在已经是这个值。\n\n" : "这会覆盖它现在的值。\n\n";
        var message = $"把「{entry.DisplayName}」的 Key 写入 Windows 用户环境变量 {name}？\n\n{note}"
            + "注意：环境变量以明文存在注册表（HKCU\\Environment）里，你这个 Windows 账户下运行的程序都能读到。"
            + "写入后，新打开的终端和程序才会看到它。";
        if (MessageBox.Show(this, message, "写入用户环境变量", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;

        WriteEnvButton.IsEnabled = false;
        try
        {
            await Task.Run(() => Environment.SetEnvironmentVariable(name, value, EnvironmentVariableTarget.User));
            ShowToast($"已写入用户环境变量 {name}，新开的终端生效");
        }
        catch (Exception ex) when (ex is SecurityException or UnauthorizedAccessException or ArgumentException)
        {
            MessageBox.Show(this, "写入失败：" + ex.Message, "密钥匣", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            WriteEnvButton.IsEnabled = true;
            if (Current == entry) EnvStatus.Text = EnvStatusText(entry);
        }
    }

    void ConsoleLinkClick(object sender, RoutedEventArgs e)
    {
        if (Current is { } x && IsWebUrl(x.ConsoleUrl))
            Process.Start(new ProcessStartInfo(x.ConsoleUrl.Trim()) { UseShellExecute = true });
    }

    async void TestClick(object sender, RoutedEventArgs e)
    {
        if (Current is not { } entry) return;
        CancelTest();
        var cts = testCts = new CancellationTokenSource();
        TestButton.IsEnabled = false;
        TestResultText.Text = "正在测试…";
        TestResultText.SetResourceReference(ForegroundProperty, "TextFillColorSecondaryBrush");
        try
        {
            var result = await KeyTester.TestAsync(entry.Clone(), cts.Token);
            if (cts.IsCancellationRequested) return;
            TestResultText.Text = (result.Ok ? "✓ " : "✗ ") + result.Message;
            TestResultText.SetResourceReference(ForegroundProperty, result.Ok ? "SystemFillColorSuccessBrush" : "SystemFillColorCriticalBrush");
        }
        catch (OperationCanceledException) { }
        finally
        {
            if (testCts == cts)
            {
                testCts = null;
                TestButton.IsEnabled = Current is { } c && KeyTester.CanTest(c);
            }
        }
    }

    void CancelTest()
    {
        testCts?.Cancel();
        testCts = null;
    }

    void DeleteClick(object sender, RoutedEventArgs e) { if (Current is { } x) DeleteEntry(x); }

    void DeleteEntry(ApiEntry entry)
    {
        if (MessageBox.Show(this, $"删除「{entry.DisplayName}」？删除后无法恢复。", "删除 API Key",
                MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK || vault is null) return;
        int index = Math.Max(0, view.IndexOf(entry));
        entries.Remove(entry);
        Persist();
        RefreshList();
        if (view.Count > 0) EntryList.SelectedIndex = Math.Min(index, view.Count - 1);
        else ShowEmpty();
        ShowToast("已删除「" + entry.DisplayName + "」");
    }

    // ───────────────────────── add / edit ─────────────────────────

    void AddClick(object sender, RoutedEventArgs e) => BeginEdit(null);
    void EditClick(object sender, RoutedEventArgs e) { if (Current is { } x) BeginEdit(x); }

    void BeginEdit(ApiEntry? entry)
    {
        if (vault is null) return;
        CancelTest();
        editing = entry;
        draft = entry?.Clone() ?? new ApiEntry();
        draftPreset = Providers.Find(draft.Provider);
        draft.PropertyChanged += DraftChanged;
        EditView.DataContext = draft;
        EditTitle.Text = entry is null ? "新增 API Key" : "编辑「" + entry.DisplayName + "」";
        EditError.Visibility = KeyGuessHint.Visibility = Visibility.Collapsed;
        SetListEnabled(false);
        EmptyView.Visibility = DetailView.Visibility = Visibility.Collapsed;
        EditView.Visibility = Visibility.Visible;
        EditView.ScrollToTop();
        Dispatcher.BeginInvoke(() => (entry is null ? KeyInput : NameInput).Focus(), DispatcherPriority.Input);
    }

    void DraftChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (draft is null || e.PropertyName != nameof(ApiEntry.Provider)) return;
        var preset = Providers.Find(draft.Provider);
        if (preset == draftPreset) return;
        // Fill the fields that are empty or still hold the previous provider's defaults.
        draft.BaseUrl = Swap(draft.BaseUrl, draftPreset?.BaseUrl, preset?.BaseUrl);
        draft.EnvVar = Swap(draft.EnvVar, draftPreset?.EnvVar, preset?.EnvVar);
        draft.ConsoleUrl = Swap(draft.ConsoleUrl, draftPreset?.ConsoleUrl, preset?.ConsoleUrl);
        draftPreset = preset;

        static string Swap(string current, string? oldDefault, string? newDefault) =>
            current.Trim().Length == 0 || current.Trim() == oldDefault ? newDefault ?? "" : current;
    }

    void KeyInputChanged(object sender, TextChangedEventArgs e)
    {
        if (draft is null || draft.Provider.Trim().Length > 0) return;
        if (Providers.GuessFromKey(KeyInput.Text) is not { } guess) return;
        draft.Provider = guess.Name;
        KeyGuessHint.Text = $"根据 Key 的前缀认出是 {guess.Name}，已自动填好服务商和常用地址";
        KeyGuessHint.Visibility = Visibility.Visible;
    }

    string? Validate(ApiEntry d)
    {
        var key = d.Key.Trim();
        if (key.Length == 0) return "API Key 不能为空。";
        if (key.Any(char.IsWhiteSpace)) return "Key 中间有空格或换行，请检查是不是粘贴完整了。";
        if (d.BaseUrl.Trim().Length > 0 && !IsWebUrl(d.BaseUrl)) return "Base URL 要以 http:// 或 https:// 开头。";
        if (d.ConsoleUrl.Trim().Length > 0 && !IsWebUrl(d.ConsoleUrl)) return "控制台网址要以 http:// 或 https:// 开头。";
        if (d.EnvVar.Trim().Length > 0 && !Snippets.IsValidName(d.EnvVar.Trim())) return "环境变量名只能包含英文字母、数字和下划线，且不能以数字开头。";
        var twin = entries.FirstOrDefault(x => x != editing && x.Key.Trim() == key);
        if (twin is not null) return $"这个 Key 已经保存在「{twin.DisplayName}」里了。";
        return null;
    }

    void SaveEditClick(object sender, RoutedEventArgs e)
    {
        if (draft is null || vault is null) return;
        if (Validate(draft) is { } error)
        {
            EditError.Text = error;
            EditError.Visibility = Visibility.Visible;
            return;
        }
        if (draft.Name.Trim().Length == 0) draft.Name = draft.DisplayName;

        bool isNew = editing is null;
        ApiEntry saved;
        if (editing is null)
        {
            saved = new ApiEntry();
            saved.CopyFrom(draft);
            entries.Add(saved);
        }
        else
        {
            editing.CopyFrom(draft);
            editing.Updated = DateTime.Now;
            saved = editing;
        }
        Persist();
        EndEdit();
        RefreshList();
        Select(saved);
        ShowToast(isNew ? "已保存「" + saved.DisplayName + "」" : "已更新「" + saved.DisplayName + "」");
    }

    void CancelEditClick(object sender, RoutedEventArgs e)
    {
        EndEdit();
        if (EntryList.SelectedItem is ApiEntry entry) ShowDetail(entry);
        else ShowEmpty();
    }

    void EndEdit()
    {
        if (draft is not null) draft.PropertyChanged -= DraftChanged;
        draft = null;
        editing = null;
        EditView.DataContext = null;
        EditView.Visibility = Visibility.Collapsed;
        SetListEnabled(true);
    }

    void SetListEnabled(bool enabled) =>
        EntryList.IsEnabled = SearchBox.IsEnabled = AddButton.IsEnabled = ImportButton.IsEnabled = SettingsButton.IsEnabled = enabled;

    // ───────────────────────── dialogs ─────────────────────────

    void ImportClick(object sender, RoutedEventArgs e)
    {
        if (vault is null) return;
        var dialog = new ImportWindow(EnvScanner.Scan(entries)) { Owner = this };
        if (dialog.ShowDialog() != true || vault is null || dialog.Selected.Count == 0) return;
        var added = dialog.Selected.Select(EnvScanner.ToEntry).ToList();
        foreach (var entry in added) entries.Add(entry);
        Persist();
        RefreshList();
        Select(added[0]);
        ShowToast($"已导入 {added.Count} 个 Key");
    }

    void SettingsClick(object sender, RoutedEventArgs e)
    {
        if (vault is null) return;
        new SettingsWindow(paths, settings, vault) { Owner = this }.ShowDialog();
    }

    void ShowToast(string text)
    {
        ToastText.Text = text;
        Toast.Visibility = Visibility.Visible;
        toastTimer.Stop();
        toastTimer.Start();
    }
}
