using System.Diagnostics;
using System.Drawing;
using System.IO.Compression;
using System.Text;
using System.Windows.Forms;

namespace AndroidLogInspectorLauncher;

internal sealed class ResultDashboardForm : Form
{
    private readonly AnalysisDashboardData _data;
    private readonly DataGridView _findingGrid;
    private readonly TextBox _detailBox;
    private readonly Button _copyEvidenceButton;
    private readonly Button _openSourceButton;

    internal ResultDashboardForm(string reportPath)
    {
        _data = AnalysisDashboardData.Load(reportPath);
        Text = "Android Log Inspector - Results";
        StartPosition = FormStartPosition.CenterParent;
        MinimumSize = new Size(920, 620);
        ClientSize = new Size(1160, 760);

        var statusBand = new Panel
        {
            Dock = DockStyle.Top,
            Height = 72,
            BackColor = StatusColor(_data),
            Padding = new Padding(16, 12, 16, 8),
        };
        var statusLabel = new Label
        {
            Dock = DockStyle.Top,
            Height = 26,
            Text = _data.OverallStatus,
            Font = new Font(Font, FontStyle.Bold),
        };
        var actionLabel = new Label
        {
            Dock = DockStyle.Fill,
            Text = _data.PriorityAction,
            AutoEllipsis = true,
        };
        statusBand.Controls.Add(actionLabel);
        statusBand.Controls.Add(statusLabel);

        var metricStrip = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            Height = 74,
            Padding = new Padding(12, 8, 12, 8),
            WrapContents = false,
        };
        metricStrip.Controls.Add(CreateMetric("CRITICAL", _data.CriticalCount, Color.FromArgb(150, 30, 30)));
        metricStrip.Controls.Add(CreateMetric("HIGH", _data.HighCount, Color.FromArgb(170, 85, 0)));
        metricStrip.Controls.Add(CreateMetric("MEDIUM", _data.MediumCount, Color.FromArgb(110, 90, 0)));
        metricStrip.Controls.Add(CreateMetric("FINDINGS", _data.Findings.Count, Color.FromArgb(45, 70, 95)));

        var actionBar = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            Height = 46,
            Padding = new Padding(8, 6, 8, 4),
            FlowDirection = FlowDirection.RightToLeft,
        };
        var closeButton = new Button { Text = "Close", AutoSize = true };
        closeButton.Click += (_, _) => Close();
        var openFolderButton = new Button { Text = "Open report folder", AutoSize = true };
        openFolderButton.Click += (_, _) => OpenReportFolder();
        var exportButton = new Button { Text = "Export support bundle", AutoSize = true };
        exportButton.Click += (_, _) => ExportSupportBundle();
        var copySummaryButton = new Button { Text = "Copy incident summary", AutoSize = true };
        copySummaryButton.Click += (_, _) => CopyIncidentSummary();
        actionBar.Controls.Add(closeButton);
        actionBar.Controls.Add(openFolderButton);
        actionBar.Controls.Add(exportButton);
        actionBar.Controls.Add(copySummaryButton);

        var tabs = new TabControl { Dock = DockStyle.Fill };
        var findingsTab = new TabPage("Cause groups");
        var collectionTab = new TabPage("Collection quality");
        tabs.TabPages.Add(findingsTab);
        tabs.TabPages.Add(collectionTab);

        _findingGrid = CreateFindingGrid();
        _findingGrid.SelectionChanged += (_, _) => UpdateFindingDetail();
        _detailBox = new TextBox
        {
            Dock = DockStyle.Fill,
            Multiline = true,
            ReadOnly = true,
            ScrollBars = ScrollBars.Vertical,
            WordWrap = true,
            BackColor = SystemColors.Window,
        };
        _copyEvidenceButton = new Button { Text = "Copy evidence", AutoSize = true, Enabled = false };
        _copyEvidenceButton.Click += (_, _) => CopyEvidence();
        _openSourceButton = new Button { Text = "Open source", AutoSize = true, Enabled = false };
        _openSourceButton.Click += (_, _) => OpenSource();

        var detailActions = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            Height = 42,
            Padding = new Padding(8, 6, 8, 4),
            FlowDirection = FlowDirection.RightToLeft,
        };
        detailActions.Controls.Add(_openSourceButton);
        detailActions.Controls.Add(_copyEvidenceButton);
        var detailPanel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(8) };
        detailPanel.Controls.Add(_detailBox);
        detailPanel.Controls.Add(detailActions);

        var findingSplit = new SplitContainer
        {
            Dock = DockStyle.Fill,
            SplitterDistance = 570,
        };
        findingSplit.Panel1.Controls.Add(_findingGrid);
        findingSplit.Panel2.Controls.Add(detailPanel);
        findingsTab.Controls.Add(findingSplit);
        PopulateCollectionQuality(collectionTab);

        Controls.Add(tabs);
        Controls.Add(actionBar);
        Controls.Add(metricStrip);
        Controls.Add(statusBand);

        if (_findingGrid.Rows.Count > 0)
        {
            _findingGrid.Rows[0].Selected = true;
            UpdateFindingDetail();
        }
        else
        {
            _detailBox.Text = "No known crash or failure signature was detected in the analyzed sources.";
        }
    }

    private DataGridView CreateFindingGrid()
    {
        var grid = new DataGridView
        {
            Dock = DockStyle.Fill,
            ReadOnly = true,
            AllowUserToAddRows = false,
            AllowUserToDeleteRows = false,
            AllowUserToResizeRows = false,
            AutoGenerateColumns = false,
            AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells,
            SelectionMode = DataGridViewSelectionMode.FullRowSelect,
            MultiSelect = false,
            RowHeadersVisible = false,
            BackgroundColor = SystemColors.Window,
            BorderStyle = BorderStyle.None,
        };
        grid.Columns.Add(new DataGridViewTextBoxColumn
        {
            HeaderText = "Severity",
            DataPropertyName = nameof(FindingGroup.Severity),
            Width = 82,
        });
        grid.Columns.Add(new DataGridViewTextBoxColumn
        {
            HeaderText = "Cause group",
            DataPropertyName = nameof(FindingGroup.Title),
            Width = 190,
        });
        grid.Columns.Add(new DataGridViewTextBoxColumn
        {
            HeaderText = "Count",
            DataPropertyName = nameof(FindingGroup.Occurrences),
            Width = 56,
        });
        grid.Columns.Add(new DataGridViewTextBoxColumn
        {
            HeaderText = "Recommended action",
            DataPropertyName = nameof(FindingGroup.RecommendedAction),
            AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill,
        });
        grid.DataSource = _data.FindingGroups.ToList();
        return grid;
    }

    private void PopulateCollectionQuality(TabPage collectionTab)
    {
        if (_data.CollectionStatus is null)
        {
            collectionTab.Controls.Add(new Label
            {
                Dock = DockStyle.Fill,
                Padding = new Padding(16),
                Text = "Collection quality is not available when analyzing an existing log folder or bugreport.",
            });
            return;
        }

        var header = new Label
        {
            Dock = DockStyle.Top,
            Height = 38,
            Padding = new Padding(12, 10, 12, 4),
            Text = $"Device: {_data.CollectionStatus.DeviceSerial}    Collected: {_data.CollectionStatus.Created}",
        };
        var list = new ListView
        {
            Dock = DockStyle.Fill,
            View = View.Details,
            FullRowSelect = true,
            GridLines = true,
        };
        list.Columns.Add("Status", 110);
        list.Columns.Add("Collection step", 330);
        list.Columns.Add("Exit code", 78);
        list.Columns.Add("Details", 560);
        foreach (var step in _data.CollectionStatus.Steps)
        {
            var item = new ListViewItem(step.Status);
            item.SubItems.Add(step.Label);
            item.SubItems.Add(step.ExitCode.ToString());
            item.SubItems.Add(step.Detail);
            item.BackColor = step.Status switch
            {
                "Collected" => Color.FromArgb(238, 248, 240),
                "NotAvailable" => Color.FromArgb(255, 248, 228),
                _ => Color.FromArgb(255, 238, 238),
            };
            list.Items.Add(item);
        }
        collectionTab.Controls.Add(list);
        collectionTab.Controls.Add(header);
    }

    private void UpdateFindingDetail()
    {
        var group = SelectedGroup();
        if (group is null)
        {
            return;
        }

        _detailBox.Text = $"Severity: {group.Severity}\r\nOccurrences: {group.Occurrences}\r\n\r\nMeaning\r\n{group.Meaning}\r\n\r\nRecommended action\r\n{group.RecommendedAction}\r\n\r\nEvidence\r\n{group.Evidence}\r\n\r\nSource\r\n{group.Source}:{group.LineNumber}";
        _copyEvidenceButton.Enabled = true;
        _openSourceButton.Enabled = !string.IsNullOrWhiteSpace(group.Source);
    }

    private FindingGroup? SelectedGroup() => _findingGrid.CurrentRow?.DataBoundItem as FindingGroup;

    private void CopyIncidentSummary()
    {
        Clipboard.SetText(_data.BuildIncidentSummary());
        MessageBox.Show("Incident summary copied to the clipboard.", "Android Log Inspector", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private void CopyEvidence()
    {
        var group = SelectedGroup();
        if (group is null)
        {
            return;
        }

        Clipboard.SetText($"{group.Evidence}\r\nSource: {group.Source}:{group.LineNumber}");
    }

    private void OpenSource()
    {
        var group = SelectedGroup();
        if (group is null)
        {
            return;
        }

        var separatorIndex = group.Source.IndexOf('!');
        var sourcePath = separatorIndex >= 0 ? group.Source[..separatorIndex] : group.Source;
        if (!File.Exists(sourcePath))
        {
            MessageBox.Show("The original source file is no longer available at the recorded location.", "Android Log Inspector", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        Process.Start(new ProcessStartInfo { FileName = sourcePath, UseShellExecute = true });
    }

    private void OpenReportFolder()
    {
        var reportDirectory = Path.GetDirectoryName(_data.ReportPath)!;
        Process.Start(new ProcessStartInfo { FileName = reportDirectory, UseShellExecute = true });
    }

    private void ExportSupportBundle()
    {
        using var dialog = new SaveFileDialog
        {
            Title = "Export support bundle",
            Filter = "ZIP archive (*.zip)|*.zip",
            FileName = $"AndroidLogInspector-support-{DateTime.Now:yyyyMMdd-HHmmss}.zip",
        };
        if (dialog.ShowDialog(this) != DialogResult.OK)
        {
            return;
        }

        if (File.Exists(dialog.FileName))
        {
            File.Delete(dialog.FileName);
        }

        using var archive = ZipFile.Open(dialog.FileName, ZipArchiveMode.Create);
        AddFile(archive, _data.ReportPath, "report/analysis-report.md");
        AddFile(archive, _data.SummaryPath, "report/analysis-summary.txt");
        AddFile(archive, _data.AnalysisJsonPath, "report/analysis.json");
        if (_data.CollectionStatusPath is not null)
        {
            AddFile(archive, _data.CollectionStatusPath, "report/collection-status.json");
        }

        var manifest = archive.CreateEntry("support-bundle-manifest.txt", CompressionLevel.Optimal);
        using var writer = new StreamWriter(manifest.Open(), Encoding.UTF8);
        writer.WriteLine("Android Log Inspector support bundle");
        writer.WriteLine("This bundle contains the analysis outputs and collection status only.");
        writer.WriteLine("Raw device logs, bugreports, account data, notifications, and network data are not included.");
        writer.WriteLine($"Created: {DateTimeOffset.Now:O}");
        writer.WriteLine($"Overall status: {_data.OverallStatus}");

        MessageBox.Show("Support bundle exported without raw device logs.", "Android Log Inspector", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private static void AddFile(ZipArchive archive, string sourcePath, string entryName)
    {
        if (File.Exists(sourcePath))
        {
            archive.CreateEntryFromFile(sourcePath, entryName, CompressionLevel.Optimal);
        }
    }

    private static Panel CreateMetric(string label, int value, Color color)
    {
        var panel = new Panel
        {
            Width = 150,
            Height = 54,
            Margin = new Padding(0, 0, 10, 0),
            BackColor = Color.FromArgb(245, 247, 249),
        };
        var caption = new Label
        {
            Dock = DockStyle.Top,
            Height = 20,
            Padding = new Padding(10, 6, 4, 0),
            Text = label,
            ForeColor = color,
        };
        var count = new Label
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(10, 0, 4, 4),
            Text = value.ToString(),
            Font = new Font(SystemFonts.DefaultFont.FontFamily, 15f, FontStyle.Bold),
            ForeColor = color,
        };
        panel.Controls.Add(count);
        panel.Controls.Add(caption);
        return panel;
    }

    private static Color StatusColor(AnalysisDashboardData data) => data.CriticalCount > 0
        ? Color.FromArgb(255, 236, 236)
        : data.HighCount > 0
            ? Color.FromArgb(255, 243, 228)
            : data.MediumCount > 0
                ? Color.FromArgb(255, 250, 224)
                : Color.FromArgb(235, 247, 239);
}
