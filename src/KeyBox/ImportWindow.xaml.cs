using System.Windows;
using KeyBox.Core;

namespace KeyBox;

public partial class ImportWindow : Window
{
    public sealed class Row(EnvCandidate candidate)
    {
        public EnvCandidate Candidate { get; } = candidate;
        public string Name => Candidate.Name;
        public string Masked => ApiEntry.Mask(Candidate.Value);
        public bool CanImport => !Candidate.AlreadyStored;
        public bool IsChecked { get; set; } = !candidate.AlreadyStored;
        public string Note => Candidate.AlreadyStored ? "已经在密钥匣里了"
            : Candidate.Guess is { } p ? "识别为 " + p.Name
            : "未识别服务商，导入后可以再编辑";
    }

    readonly List<Row> rows;

    public ImportWindow(List<EnvCandidate> candidates)
    {
        InitializeComponent();
        rows = candidates.Select(c => new Row(c)).ToList();
        Rows.ItemsSource = rows;
        NoneText.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ImportButton.IsEnabled = rows.Any(r => r.CanImport);
    }

    public List<EnvCandidate> Selected { get; private set; } = [];

    void ImportClick(object sender, RoutedEventArgs e)
    {
        Selected = rows.Where(r => r.CanImport && r.IsChecked).Select(r => r.Candidate).ToList();
        DialogResult = true;
    }
}
