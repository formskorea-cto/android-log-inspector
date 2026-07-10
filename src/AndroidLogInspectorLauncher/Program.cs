using System.Diagnostics;
using System.Drawing;
using System.Reflection;
using System.Text;
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

    private readonly string[] _arguments;
    private readonly Label _statusLabel;
    private readonly ProgressBar _progressBar;
    private readonly TextBox _progressLog;
    private readonly Button _openResultsButton;
    private readonly Button _openSummaryButton;
    private readonly Button _openFolderButton;
    private readonly Button _closeButton;
    private readonly StringBuilder _combinedOutput = new();
    private readonly object _outputGate = new();

    private Process? _process;
    private string? _reportPath;
    private bool _finished;
    private bool _cancelled;

    internal InspectorForm(string[] arguments)
    {
        _arguments = arguments;
        var version = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "development";
        Text = $"Android Log Inspector {version}";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(720, 420);
        ClientSize = new Size(900, 560);

        _statusLabel = new Label
        {
            Dock = DockStyle.Top,
            Height = 42,
            Padding = new Padding(12, 10, 12, 4),
            Text = "Preparing Android log collection...",
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

        _openResultsButton = new Button
        {
            Text = "View result dashboard",
            AutoSize = true,
            Enabled = false,
        };
        _openResultsButton.Click += (_, _) => OpenResultDashboard();

        _openSummaryButton = new Button
        {
            Text = "Open summary",
            AutoSize = true,
            Enabled = false,
        };
        _openSummaryButton.Click += (_, _) => OpenSummary();
        _openFolderButton = new Button
        {
            Text = "Open report folder",
            AutoSize = true,
            Enabled = false,
        };
        _openFolderButton.Click += (_, _) => OpenReportFolder();
        _closeButton = new Button
        {
            Text = "Cancel",
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
        buttonPanel.Controls.Add(_openFolderButton);
        buttonPanel.Controls.Add(_openSummaryButton);
        buttonPanel.Controls.Add(_openResultsButton);

        Controls.Add(_progressLog);
        Controls.Add(buttonPanel);
        Controls.Add(_progressBar);
        Controls.Add(_statusLabel);

        Shown += async (_, _) => await RunInspectorAsync();
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

            AppendOutput("Starting Android Log Inspector...");
            _process.Start();
            _process.BeginOutputReadLine();
            _process.BeginErrorReadLine();
            await _process.WaitForExitAsync();
            await Task.WhenAll(standardOutputFinished.Task, standardErrorFinished.Task);

            if (_cancelled)
            {
                Complete("Collection canceled.", succeeded: false);
                return;
            }

            var output = GetCombinedOutput();
            _reportPath = FindReportPath(output);
            if (_process.ExitCode == 0 && _reportPath is not null && File.Exists(_reportPath))
            {
                _openResultsButton.Enabled = true;
                _openSummaryButton.Enabled = true;
                _openFolderButton.Enabled = true;
                Complete("Collection and analysis completed.", succeeded: true);
                BeginInvoke(new Action(OpenResultDashboard));
                return;
            }

            Complete("Collection or analysis failed. Review the progress log for details.", succeeded: false);
        }
        catch (Exception exception)
        {
            AppendOutput("ERROR: " + exception.Message);
            Complete("Collection or analysis failed. Review the progress log for details.", succeeded: false);
        }
        finally
        {
            _process?.Dispose();
            _process = null;
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
                "Stop the current collection and analysis?",
                "Android Log Inspector",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question) != DialogResult.Yes)
        {
            return;
        }

        _cancelled = true;
        _statusLabel.Text = "Canceling collection...";
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
        _statusLabel.Text = status;
        _progressBar.Style = ProgressBarStyle.Continuous;
        _progressBar.Value = succeeded ? _progressBar.Maximum : _progressBar.Minimum;
        _closeButton.Text = "Close";
        _closeButton.Enabled = true;
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
                "Android Log Inspector - result dashboard failed",
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

        if (line.StartsWith("[Android Log Inspector]", StringComparison.OrdinalIgnoreCase))
        {
            _statusLabel.Text = line;
        }
    }

    private string GetCombinedOutput()
    {
        lock (_outputGate)
        {
            return _combinedOutput.ToString();
        }
    }

    private static void ExtractEmbeddedScript(string destinationPath)
    {
        var assembly = Assembly.GetExecutingAssembly();
        using var source = assembly.GetManifestResourceStream("AndroidLogInspector.ps1")
            ?? throw new InvalidOperationException("Embedded analysis script is missing.");
        using var destination = File.Create(destinationPath);
        source.CopyTo(destination);
    }

    private static string? FindReportPath(string output)
    {
        const string marker = "Report created: ";
        var markerIndex = output.LastIndexOf(marker, StringComparison.Ordinal);
        if (markerIndex < 0)
        {
            return null;
        }

        var reportStart = markerIndex + marker.Length;
        var reportEnd = output.IndexOfAny(['\r', '\n'], reportStart);
        return (reportEnd < 0 ? output[reportStart..] : output[reportStart..reportEnd]).Trim();
    }
}
