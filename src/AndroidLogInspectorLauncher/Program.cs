using System.Diagnostics;
using System.Drawing;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace AndroidLogInspectorLauncher;

internal static class Program
{
    [STAThread]
    private static void Main(string[] arguments)
    {
        Application.EnableVisualStyles();
        Application.Run(new InspectorForm(arguments));
    }
}

internal sealed class InspectorForm : Form
{
    private const int MaximumVisibleLogCharacters = 120_000;
    private const string InspectorPrefix = "[Android Log Inspector] ";
    private const string StageAdb = "ADB 연결 확인";
    private const string StageCollect = "로그 수집";
    private const string StageAnalyze = "로그 분석";
    private const string StageReport = "보고서 생성";

    private static readonly Regex ProgressPattern = new(
        @"^\[Android Log Inspector\] Progress: (?<completed>\d+)/(?<total>\d+) (?<message>.+)$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex StagePattern = new(
        @"^\[Android Log Inspector\] Stage: (?<state>Running|Completed|Failed)\|(?<stage>[^|]+)\|(?<message>.*)$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex ArtifactPattern = new(
        @"^\[Android Log Inspector\] Artifact: (?<kind>Directory|File)\|(?<status>[^|]+)\|(?<path>.+)$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly StageDefinition[] StageDefinitions =
    [
        new(1, StageAdb),
        new(2, StageCollect),
        new(3, StageAnalyze),
        new(4, StageReport),
    ];

    private readonly string[] _arguments;
    private readonly Label _statusLabel;
    private readonly ProgressBar _progressBar;
    private readonly TextBox _progressLog;
    private readonly Label _collectedDataLabel;
    private readonly ListView _collectedDataList;
    private readonly Button _openResultsButton;
    private readonly Button _openSummaryButton;
    private readonly Button _openFolderButton;
    private readonly Button _openCollectionButton;
    private readonly Button _openSelectedArtifactButton;
    private readonly Button _restartButton;
    private readonly Button _closeButton;
    private readonly Dictionary<string, Button> _stageButtons = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _listedArtifacts = new(StringComparer.OrdinalIgnoreCase);
    private readonly StringBuilder _combinedOutput = new();
    private readonly object _outputGate = new();

    private Process? _process;
    private string? _reportPath;
    private string? _collectionDirectory;
    private string? _failedStage;
    private string? _failedStageDetail;
    private bool _finished;
    private bool _cancelled;
    private bool _runInProgress;

    internal InspectorForm(string[] arguments)
    {
        _arguments = arguments;
        var version = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "development";
        Text = $"Android Log Inspector {version}";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(820, 560);
        ClientSize = new Size(1040, 720);

        _statusLabel = new Label
        {
            Dock = DockStyle.Top,
            Height = 42,
            Padding = new Padding(12, 10, 12, 4),
            Text = "Android 로그 수집을 준비하는 중...",
            AutoEllipsis = true,
        };
        _progressBar = new ProgressBar
        {
            Dock = DockStyle.Top,
            Height = 18,
            Style = ProgressBarStyle.Marquee,
            MarqueeAnimationSpeed = 30,
        };
        _progressLog = new TextBox
        {
            Dock = DockStyle.Fill,
            Multiline = true,
            ReadOnly = true,
            ScrollBars = ScrollBars.Both,
            WordWrap = false,
            Font = new Font(FontFamily.GenericMonospace, 9f),
            BackColor = SystemColors.Window,
        };

        var stagePanel = CreateStagePanel();

        _collectedDataLabel = new Label
        {
            Dock = DockStyle.Top,
            Height = 28,
            Padding = new Padding(8, 7, 8, 2),
            Text = "현재 수집된 데이터: 0개",
            AutoEllipsis = true,
        };
        _collectedDataList = new ListView
        {
            Dock = DockStyle.Fill,
            View = View.Details,
            FullRowSelect = true,
            GridLines = true,
            HideSelection = false,
        };
        _collectedDataList.Columns.Add("상태", 120);
        _collectedDataList.Columns.Add("수집 데이터", 360);
        _collectedDataList.Columns.Add("위치", 520);
        _collectedDataList.SelectedIndexChanged += (_, _) => UpdateArtifactButtons();
        _collectedDataList.DoubleClick += (_, _) => OpenSelectedArtifact();

        var collectionPanel = new Panel
        {
            Dock = DockStyle.Bottom,
            Height = 142,
            Padding = new Padding(8, 2, 8, 8),
        };
        collectionPanel.Controls.Add(_collectedDataList);
        collectionPanel.Controls.Add(_collectedDataLabel);

        _openResultsButton = new Button
        {
            Text = "결과 대시보드 보기",
            AutoSize = true,
            Enabled = false,
        };
        _openResultsButton.Click += (_, _) => OpenResultDashboard();

        _openSummaryButton = new Button
        {
            Text = "요약 열기",
            AutoSize = true,
            Enabled = false,
        };
        _openSummaryButton.Click += (_, _) => OpenSummary();

        _openFolderButton = new Button
        {
            Text = "보고서 폴더 열기",
            AutoSize = true,
            Enabled = false,
        };
        _openFolderButton.Click += (_, _) => OpenReportFolder();

        _openCollectionButton = new Button
        {
            Text = "수집 폴더 열기",
            AutoSize = true,
            Enabled = false,
        };
        _openCollectionButton.Click += (_, _) => OpenCollectionFolder();

        _openSelectedArtifactButton = new Button
        {
            Text = "선택 로그 열기",
            AutoSize = true,
            Enabled = false,
        };
        _openSelectedArtifactButton.Click += (_, _) => OpenSelectedArtifact();

        _restartButton = new Button
        {
            Text = "다시 시작",
            AutoSize = true,
            Enabled = false,
        };
        _restartButton.Click += (_, _) => BeginRun();

        _closeButton = new Button
        {
            Text = "취소",
            AutoSize = true,
        };
        _closeButton.Click += (_, _) => CancelOrClose();

        var buttonPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            Height = 52,
            Padding = new Padding(8),
            FlowDirection = FlowDirection.RightToLeft,
        };
        buttonPanel.Controls.Add(_closeButton);
        buttonPanel.Controls.Add(_restartButton);
        buttonPanel.Controls.Add(_openCollectionButton);
        buttonPanel.Controls.Add(_openSelectedArtifactButton);
        buttonPanel.Controls.Add(_openFolderButton);
        buttonPanel.Controls.Add(_openSummaryButton);
        buttonPanel.Controls.Add(_openResultsButton);

        Controls.Add(_progressLog);
        Controls.Add(collectionPanel);
        Controls.Add(buttonPanel);
        Controls.Add(_progressBar);
        Controls.Add(stagePanel);
        Controls.Add(_statusLabel);

        ResetStageButtons();
        Shown += (_, _) => BeginRun();
    }

    protected override void OnFormClosing(FormClosingEventArgs eventArgs)
    {
        if (!_finished && !_cancelled)
        {
            eventArgs.Cancel = true;
            CancelOrClose();
            return;
        }

        base.OnFormClosing(eventArgs);
    }

    private async void BeginRun()
    {
        if (_runInProgress)
        {
            return;
        }

        ResetForRun();
        await RunInspectorAsync();
    }

    private void ResetForRun()
    {
        _runInProgress = true;
        _finished = false;
        _cancelled = false;
        _reportPath = null;
        _collectionDirectory = null;
        _failedStage = null;
        _failedStageDetail = null;

        lock (_outputGate)
        {
            _combinedOutput.Clear();
        }

        _listedArtifacts.Clear();
        _progressLog.Clear();
        _collectedDataList.Items.Clear();
        _statusLabel.Text = "Android 로그 수집을 준비하는 중...";
        _collectedDataLabel.Text = "현재 수집된 데이터: 0개";
        _progressBar.Style = ProgressBarStyle.Marquee;
        _progressBar.MarqueeAnimationSpeed = 30;
        _progressBar.Minimum = 0;
        _progressBar.Maximum = 100;
        _progressBar.Value = 0;
        _openResultsButton.Enabled = false;
        _openSummaryButton.Enabled = false;
        _openFolderButton.Enabled = false;
        _openCollectionButton.Enabled = false;
        _openSelectedArtifactButton.Enabled = false;
        _restartButton.Enabled = false;
        _closeButton.Text = "취소";
        _closeButton.Enabled = true;
        ResetStageButtons();
    }

    private async Task RunInspectorAsync()
    {
        var toolRoot = AppContext.BaseDirectory;
        var temporaryDirectory = Path.Combine(Path.GetTempPath(), "AndroidLogInspector", Guid.NewGuid().ToString("N"));
        var scriptPath = Path.Combine(temporaryDirectory, "AndroidLogInspector.ps1");

        try
        {
            Directory.CreateDirectory(temporaryDirectory);
            ExtractEmbeddedScript(scriptPath);
            _process = CreatePowerShellProcess(scriptPath, toolRoot);

            var standardOutputFinished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var standardErrorFinished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _process.OutputDataReceived += (_, eventArgs) =>
            {
                if (eventArgs.Data is null)
                {
                    standardOutputFinished.TrySetResult();
                }
                else
                {
                    AppendOutput(eventArgs.Data);
                }
            };
            _process.ErrorDataReceived += (_, eventArgs) =>
            {
                if (eventArgs.Data is null)
                {
                    standardErrorFinished.TrySetResult();
                }
                else
                {
                    AppendOutput(eventArgs.Data);
                }
            };

            AppendOutput("Android Log Inspector를 시작합니다...");
            _process.Start();
            _process.BeginOutputReadLine();
            _process.BeginErrorReadLine();
            await _process.WaitForExitAsync();
            await Task.WhenAll(standardOutputFinished.Task, standardErrorFinished.Task);

            RefreshCollectedFilesFromDirectory();
            if (_cancelled)
            {
                Complete("수집이 취소되었습니다.", succeeded: false);
                return;
            }

            var output = GetCombinedOutput();
            _reportPath = FindReportPath(output);
            if (_process.ExitCode == 0 && _reportPath is not null && File.Exists(_reportPath))
            {
                _openResultsButton.Enabled = true;
                _openSummaryButton.Enabled = true;
                _openFolderButton.Enabled = true;
                Complete("수집과 분석이 완료되었습니다.", succeeded: true);
                BeginInvoke(new Action(OpenResultDashboard));
                return;
            }

            Complete("수집 또는 분석에 실패했습니다. 진행 로그에서 상세 내용을 확인하세요.", succeeded: false);
        }
        catch (Exception exception)
        {
            AppendOutput("오류: " + exception.Message);
            RefreshCollectedFilesFromDirectory();
            Complete("수집 또는 분석에 실패했습니다. 진행 로그에서 상세 내용을 확인하세요.", succeeded: false);
        }
        finally
        {
            _process?.Dispose();
            _process = null;
            _runInProgress = false;
            _restartButton.Enabled = true;
            UpdateArtifactButtons();
            try
            {
                Directory.Delete(temporaryDirectory, recursive: true);
            }
            catch
            {
                // Temporary extraction cleanup is best-effort only.
            }
        }
    }

    private Process CreatePowerShellProcess(string scriptPath, string toolRoot)
    {
        var powerShellPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");
        if (!File.Exists(powerShellPath))
        {
            powerShellPath = "powershell.exe";
        }

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = powerShellPath,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            },
        };

        process.StartInfo.ArgumentList.Add("-NoProfile");
        process.StartInfo.ArgumentList.Add("-ExecutionPolicy");
        process.StartInfo.ArgumentList.Add("Bypass");
        process.StartInfo.ArgumentList.Add("-File");
        process.StartInfo.ArgumentList.Add(scriptPath);
        process.StartInfo.ArgumentList.Add("-ToolRoot");
        process.StartInfo.ArgumentList.Add(toolRoot);
        foreach (var argument in _arguments)
        {
            process.StartInfo.ArgumentList.Add(argument);
        }

        return process;
    }

    private void CancelOrClose()
    {
        if (_finished)
        {
            Close();
            return;
        }

        if (MessageBox.Show(
                "현재 수집과 분석을 중단할까요?",
                "Android Log Inspector",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question) != DialogResult.Yes)
        {
            return;
        }

        _cancelled = true;
        _statusLabel.Text = "수집을 취소하는 중...";
        _closeButton.Enabled = false;
        try
        {
            if (_process is { HasExited: false })
            {
                _process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
            // The process completed before cancellation was requested.
        }
    }

    private void Complete(string status, bool succeeded)
    {
        _finished = true;
        if (!succeeded && _failedStage is not null)
        {
            status = string.IsNullOrWhiteSpace(_failedStageDetail)
                ? $"중단 단계: {_failedStage}"
                : $"중단 단계: {_failedStage} - {_failedStageDetail}";
        }

        _statusLabel.Text = status;
        _progressBar.Style = ProgressBarStyle.Continuous;
        if (succeeded)
        {
            _progressBar.Value = _progressBar.Maximum;
        }
        else if (_progressBar.Value < _progressBar.Minimum || _progressBar.Value > _progressBar.Maximum)
        {
            _progressBar.Value = _progressBar.Minimum;
        }

        _closeButton.Text = "닫기";
        _closeButton.Enabled = true;
        _restartButton.Enabled = true;
        UpdateCollectionSummary();
    }

    private TableLayoutPanel CreateStagePanel()
    {
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            Height = 76,
            Padding = new Padding(8, 6, 8, 6),
            ColumnCount = StageDefinitions.Length,
            RowCount = 1,
        };
        for (var index = 0; index < StageDefinitions.Length; index++)
        {
            panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f / StageDefinitions.Length));
            var definition = StageDefinitions[index];
            var button = new Button
            {
                Dock = DockStyle.Fill,
                Margin = new Padding(4, 0, 4, 0),
                FlatStyle = FlatStyle.Flat,
                UseVisualStyleBackColor = false,
                TextAlign = ContentAlignment.MiddleCenter,
                TabStop = false,
            };
            button.FlatAppearance.BorderSize = 1;
            _stageButtons[definition.Name] = button;
            panel.Controls.Add(button, index, 0);
        }

        return panel;
    }

    private void ResetStageButtons()
    {
        foreach (var definition in StageDefinitions)
        {
            UpdateStageButton(definition.Name, "Pending");
        }
    }

    private void UpdateStageButton(string stage, string state)
    {
        if (!_stageButtons.TryGetValue(stage, out var button))
        {
            return;
        }

        var definition = StageDefinitions.First(item => item.Name.Equals(stage, StringComparison.OrdinalIgnoreCase));
        var displayState = state switch
        {
            "Running" => "진행 중",
            "Completed" => "완료",
            "Failed" => "중단",
            _ => "진행 전",
        };
        button.Text = $"{definition.Order}. {definition.Name}{Environment.NewLine}{displayState}";
        button.BackColor = state switch
        {
            "Running" => Color.FromArgb(41, 111, 180),
            "Completed" => Color.FromArgb(31, 140, 75),
            "Failed" => Color.FromArgb(185, 45, 45),
            _ => Color.FromArgb(235, 238, 242),
        };
        button.ForeColor = state == "Pending" ? Color.FromArgb(55, 60, 66) : Color.White;
        button.FlatAppearance.BorderColor = state switch
        {
            "Running" => Color.FromArgb(26, 82, 136),
            "Completed" => Color.FromArgb(20, 105, 55),
            "Failed" => Color.FromArgb(135, 25, 25),
            _ => Color.FromArgb(200, 206, 214),
        };
    }

    private void OpenSummary()
    {
        if (_reportPath is null)
        {
            return;
        }

        var summaryPath = Path.Combine(Path.GetDirectoryName(_reportPath)!, "analysis-summary.txt");
        if (File.Exists(summaryPath))
        {
            Process.Start(new ProcessStartInfo { FileName = summaryPath, UseShellExecute = true });
        }
    }

    private void OpenResultDashboard()
    {
        if (_reportPath is null || !File.Exists(_reportPath))
        {
            return;
        }

        try
        {
            using var dashboard = new ResultDashboardForm(_reportPath);
            dashboard.ShowDialog(this);
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                exception.Message,
                "Android Log Inspector - 결과 대시보드 오류",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private void OpenReportFolder()
    {
        if (_reportPath is null)
        {
            return;
        }

        var reportDirectory = Path.GetDirectoryName(_reportPath)!;
        Process.Start(new ProcessStartInfo { FileName = reportDirectory, UseShellExecute = true });
    }

    private void OpenCollectionFolder()
    {
        if (string.IsNullOrWhiteSpace(_collectionDirectory) || !Directory.Exists(_collectionDirectory))
        {
            MessageBox.Show(this, "수집 폴더를 아직 사용할 수 없습니다.", "Android Log Inspector", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        Process.Start(new ProcessStartInfo { FileName = _collectionDirectory, UseShellExecute = true });
    }

    private void OpenSelectedArtifact()
    {
        if (_collectedDataList.SelectedItems.Count != 1 || _collectedDataList.SelectedItems[0].Tag is not string path)
        {
            return;
        }

        if (!File.Exists(path))
        {
            MessageBox.Show(this, "선택한 로그 파일을 찾을 수 없습니다:\n" + path, "Android Log Inspector", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
    }

    private void AppendOutput(string line)
    {
        lock (_outputGate)
        {
            _combinedOutput.AppendLine(line);
        }

        if (IsDisposed || !IsHandleCreated)
        {
            return;
        }

        try
        {
            BeginInvoke(new Action<string>(AppendOutputToUi), line);
        }
        catch (InvalidOperationException)
        {
            // The form has already been disposed.
        }
    }

    private void AppendOutputToUi(string line)
    {
        if (IsDisposed)
        {
            return;
        }

        _progressLog.AppendText(line + Environment.NewLine);
        if (_progressLog.TextLength > MaximumVisibleLogCharacters)
        {
            _progressLog.Select(0, _progressLog.TextLength - MaximumVisibleLogCharacters);
            _progressLog.SelectedText = string.Empty;
        }
        _progressLog.SelectionStart = _progressLog.TextLength;
        _progressLog.ScrollToCaret();

        if (TryApplyProgress(line) || TryApplyStage(line) || TryApplyArtifact(line))
        {
            return;
        }

        if (line.StartsWith(InspectorPrefix, StringComparison.OrdinalIgnoreCase))
        {
            _statusLabel.Text = StripInspectorPrefix(line);
        }
    }

    private bool TryApplyProgress(string line)
    {
        var match = ProgressPattern.Match(line);
        if (!match.Success
            || !int.TryParse(match.Groups["completed"].Value, out var completed)
            || !int.TryParse(match.Groups["total"].Value, out var total)
            || total < 1)
        {
            return false;
        }

        _progressBar.Style = ProgressBarStyle.Continuous;
        _progressBar.Minimum = 0;
        _progressBar.Maximum = total;
        _progressBar.Value = Math.Clamp(completed, _progressBar.Minimum, _progressBar.Maximum);
        _statusLabel.Text = $"{completed}/{total} {match.Groups["message"].Value}";
        return true;
    }

    private bool TryApplyStage(string line)
    {
        var match = StagePattern.Match(line);
        if (!match.Success)
        {
            return false;
        }

        var state = match.Groups["state"].Value;
        var stage = match.Groups["stage"].Value.Trim();
        var message = match.Groups["message"].Value.Trim();
        UpdateStageButton(stage, state);

        if (state == "Failed")
        {
            _failedStage = stage;
            _failedStageDetail = message;
        }

        if (!string.IsNullOrWhiteSpace(message))
        {
            _statusLabel.Text = $"{stage}: {message}";
        }
        else
        {
            _statusLabel.Text = $"{stage}: {StageStateText(state)}";
        }

        UpdateCollectionSummary();
        return true;
    }

    private bool TryApplyArtifact(string line)
    {
        var match = ArtifactPattern.Match(line);
        if (!match.Success)
        {
            return false;
        }

        var kind = match.Groups["kind"].Value;
        var status = match.Groups["status"].Value.Trim();
        var path = match.Groups["path"].Value.Trim();
        if (kind.Equals("Directory", StringComparison.OrdinalIgnoreCase))
        {
            _collectionDirectory = path;
            _openCollectionButton.Enabled = Directory.Exists(path);
            RefreshCollectedFilesFromDirectory();
        }
        else
        {
            AddCollectedArtifact(status, path);
        }

        UpdateArtifactButtons();
        UpdateCollectionSummary();
        return true;
    }

    private void AddCollectedArtifact(string status, string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !_listedArtifacts.Add(path))
        {
            return;
        }

        var displayName = DisplayArtifactName(path);
        var displayFolder = Path.GetDirectoryName(path) ?? string.Empty;
        var item = new ListViewItem(status);
        item.SubItems.Add(displayName);
        item.SubItems.Add(displayFolder);
        item.Tag = path;
        item.BackColor = status switch
        {
            var value when value.Contains("오류", StringComparison.OrdinalIgnoreCase) => Color.FromArgb(255, 238, 238),
            var value when value.Contains("권한", StringComparison.OrdinalIgnoreCase) => Color.FromArgb(255, 248, 228),
            _ => Color.FromArgb(238, 248, 240),
        };
        _collectedDataList.Items.Add(item);
    }

    private string DisplayArtifactName(string path)
    {
        if (!string.IsNullOrWhiteSpace(_collectionDirectory))
        {
            try
            {
                var relative = Path.GetRelativePath(_collectionDirectory, path);
                if (!relative.StartsWith("..", StringComparison.Ordinal) && !Path.IsPathRooted(relative))
                {
                    return relative;
                }
            }
            catch
            {
                // Fall back to the leaf name below.
            }
        }

        return Path.GetFileName(path);
    }

    private void RefreshCollectedFilesFromDirectory()
    {
        if (string.IsNullOrWhiteSpace(_collectionDirectory) || !Directory.Exists(_collectionDirectory))
        {
            return;
        }

        foreach (var path in Directory.EnumerateFiles(_collectionDirectory, "*", SearchOption.AllDirectories).OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
        {
            AddCollectedArtifact("현재 파일", path);
        }
    }

    private void UpdateArtifactButtons()
    {
        _openCollectionButton.Enabled = !string.IsNullOrWhiteSpace(_collectionDirectory) && Directory.Exists(_collectionDirectory);
        _openSelectedArtifactButton.Enabled = _collectedDataList.SelectedItems.Count == 1
            && _collectedDataList.SelectedItems[0].Tag is string path
            && File.Exists(path);
    }

    private void UpdateCollectionSummary()
    {
        var countText = $"현재 수집된 데이터: {_collectedDataList.Items.Count}개";
        if (_failedStage is not null)
        {
            countText = string.IsNullOrWhiteSpace(_failedStageDetail)
                ? $"중단 단계: {_failedStage} | {countText}"
                : $"중단 단계: {_failedStage} - {_failedStageDetail} | {countText}";
        }

        _collectedDataLabel.Text = countText;
    }

    private string GetCombinedOutput()
    {
        lock (_outputGate)
        {
            return _combinedOutput.ToString();
        }
    }

    private static string StripInspectorPrefix(string line) =>
        line.StartsWith(InspectorPrefix, StringComparison.OrdinalIgnoreCase)
            ? line[InspectorPrefix.Length..]
            : line;

    private static string StageStateText(string state) => state switch
    {
        "Running" => "진행 중",
        "Completed" => "완료",
        "Failed" => "중단",
        _ => "진행 전",
    };

    private static void ExtractEmbeddedScript(string destinationPath)
    {
        var assembly = Assembly.GetExecutingAssembly();
        using var source = assembly.GetManifestResourceStream("AndroidLogInspector.ps1")
            ?? throw new InvalidOperationException("Embedded analysis script is missing.");
        using var reader = new StreamReader(source, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        using var writer = new StreamWriter(destinationPath, append: false, encoding: new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
        writer.Write(reader.ReadToEnd());
    }

    private static string? FindReportPath(string output)
    {
        const string marker = "보고서 생성 완료: ";
        var markerIndex = output.LastIndexOf(marker, StringComparison.Ordinal);
        if (markerIndex < 0)
        {
            return null;
        }

        var reportStart = markerIndex + marker.Length;
        var reportEnd = output.IndexOfAny(['\r', '\n'], reportStart);
        return (reportEnd < 0 ? output[reportStart..] : output[reportStart..reportEnd]).Trim();
    }

    private sealed record StageDefinition(int Order, string Name);
}
