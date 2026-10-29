using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;

namespace KeyBox.Core;

/// <summary>
/// Copies secrets so that Windows clipboard history (Win+V) and cloud clipboard skip them,
/// and clears the clipboard again after a delay if it still holds what we put there.
/// </summary>
public static class SecureClipboard
{
    static string? copied;
    static DispatcherTimer? timer;

    public static void Copy(string text, int clearAfterSeconds)
    {
        var data = new DataObject();
        data.SetText(text, TextDataFormat.UnicodeText);
        data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[4]));
        data.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
        data.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
        Retry(() => Clipboard.SetDataObject(data, copy: true));
        copied = text;

        timer?.Stop();
        if (clearAfterSeconds <= 0) return;
        timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(clearAfterSeconds) };
        timer.Tick += (_, _) => ClearIfOurs();
        timer.Start();
    }

    /// <summary>Ordinary copy for things that are not secret (a Base URL).</summary>
    public static void CopyPlain(string text) => Retry(() => Clipboard.SetDataObject(text, copy: true));

    /// <summary>Clears the clipboard only if it still contains the last secret we copied.</summary>
    public static void ClearIfOurs()
    {
        timer?.Stop();
        if (copied is null) return;
        try
        {
            if (Clipboard.ContainsText() && Clipboard.GetText() == copied) Retry(Clipboard.Clear);
        }
        catch (COMException) { }
        copied = null;
    }

    // Another program can hold the clipboard open for a moment (CLIPBRD_E_CANT_OPEN).
    static void Retry(Action action)
    {
        for (int attempt = 0; ; attempt++)
        {
            try { action(); return; }
            catch (COMException) when (attempt < 5) { Thread.Sleep(40); }
        }
    }
}
