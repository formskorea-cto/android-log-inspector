using System.Text;
using System.Text.Json;

namespace AndroidLogInspectorLauncher;

internal sealed class AnalysisFinding
{
    public string Rule { get; init; } = string.Empty;
    public string Severity { get; init; } = string.Empty;
    public string Title { get; init; } = string.Empty;
    public string Source { get; init; } = string.Empty;
    public int LineNumber { get; init; }
    public string Evidence { get; init; } = string.Empty;
    public string Meaning { get; init; } = string.Empty;
    public string RecommendedAction { get; init; } = string.Empty;
}

internal sealed class FindingGroup
{
    public string Rule { get; init; } = string.Empty;
    public string Severity { get; init; } = string.Empty;
    public string Title { get; init; } = string.Empty;
    public int Occurrences { get; init; }
    public string Source { get; init; } = string.Empty;
    public int LineNumber { get; init; }
    public string Evidence { get; init; } = string.Empty;
    public string Meaning { get; init; } = string.Empty;
    public string RecommendedAction { get; init; } = string.Empty;
}

internal sealed class CollectionStatusReport
{
    public int SchemaVersion { get; init; }
    public string DeviceSerial { get; init; } = string.Empty;
    public string Created { get; init; } = string.Empty;
    public List<CollectionStep> Steps { get; init; } = [];
}

internal sealed class CollectionStep
{
    public string Status { get; init; } = string.Empty;
    public string Label { get; init; } = string.Empty;
    public int ExitCode { get; init; }
    public string Detail { get; init; } = string.Empty;
    public string OutputFile { get; init; } = string.Empty;
}

internal sealed class AnalysisDashboardData
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private AnalysisDashboardData(
        string reportPath,
        IReadOnlyList<AnalysisFinding> findings,
        IReadOnlyList<FindingGroup> findingGroups,
        CollectionStatusReport? collectionStatus)
    {
        ReportPath = reportPath;
        Findings = findings;
        FindingGroups = findingGroups;
        CollectionStatus = collectionStatus;
    }

    public string ReportPath { get; }
    public IReadOnlyList<AnalysisFinding> Findings { get; }
    public IReadOnlyList<FindingGroup> FindingGroups { get; }
    public CollectionStatusReport? CollectionStatus { get; }
    public int CriticalCount => Findings.Count(finding => finding.Severity.Equals("CRITICAL", StringComparison.OrdinalIgnoreCase));
    public int HighCount => Findings.Count(finding => finding.Severity.Equals("HIGH", StringComparison.OrdinalIgnoreCase));
    public int MediumCount => Findings.Count(finding => finding.Severity.Equals("MEDIUM", StringComparison.OrdinalIgnoreCase));
    public string SummaryPath => Path.Combine(Path.GetDirectoryName(ReportPath)!, "analysis-summary.txt");
    public string AnalysisJsonPath => Path.Combine(Path.GetDirectoryName(ReportPath)!, "analysis.json");
    public string? CollectionStatusPath { get; private init; }
    public string? CollectionDirectory { get; private init; }

    public string OverallStatus => CriticalCount > 0
        ? "Critical device fault detected"
        : HighCount > 0
            ? "High-priority crash signature detected"
            : MediumCount > 0
                ? "Diagnostic warning detected"
                : "No known critical signature detected";

    public string PriorityAction => FindingGroups.FirstOrDefault()?.RecommendedAction
        ?? "Review the report and retain the collected logs for comparison.";

    public static AnalysisDashboardData Load(string reportPath)
    {
        var reportDirectory = Path.GetDirectoryName(reportPath)
            ?? throw new InvalidOperationException("The report path has no parent directory.");
        var analysisJsonPath = Path.Combine(reportDirectory, "analysis.json");
        if (!File.Exists(analysisJsonPath))
        {
            throw new FileNotFoundException("analysis.json was not found next to the report.", analysisJsonPath);
        }

        var findings = JsonSerializer.Deserialize<List<AnalysisFinding>>(File.ReadAllText(analysisJsonPath), JsonOptions)
            ?? [];
        var groups = findings
            .GroupBy(finding => string.IsNullOrWhiteSpace(finding.Rule) ? finding.Title : finding.Rule)
            .Select(group =>
            {
                var sample = group.First();
                return new FindingGroup
                {
                    Rule = sample.Rule,
                    Severity = sample.Severity,
                    Title = sample.Title,
                    Occurrences = group.Count(),
                    Source = sample.Source,
                    LineNumber = sample.LineNumber,
                    Evidence = sample.Evidence,
                    Meaning = sample.Meaning,
                    RecommendedAction = sample.RecommendedAction,
                };
            })
            .OrderBy(group => SeverityRank(group.Severity))
            .ThenBy(group => group.Title, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var collectionDirectory = Directory.GetParent(reportDirectory)?.FullName;
        var collectionStatusPath = collectionDirectory is null
            ? null
            : Path.Combine(collectionDirectory, "collection-status.json");
        CollectionStatusReport? collectionStatus = null;
        if (collectionStatusPath is not null && File.Exists(collectionStatusPath))
        {
            collectionStatus = JsonSerializer.Deserialize<CollectionStatusReport>(File.ReadAllText(collectionStatusPath), JsonOptions);
        }

        return new AnalysisDashboardData(reportPath, findings, groups, collectionStatus)
        {
            CollectionStatusPath = collectionStatus is null ? null : collectionStatusPath,
            CollectionDirectory = collectionStatus is null ? null : collectionDirectory,
        };
    }

    public string BuildIncidentSummary()
    {
        var builder = new StringBuilder();
        builder.AppendLine("Android Log Inspector incident summary");
        builder.AppendLine($"Status: {OverallStatus}");
        builder.AppendLine($"Findings: Critical {CriticalCount}, High {HighCount}, Medium {MediumCount}, Total {Findings.Count}");
        builder.AppendLine($"Primary action: {PriorityAction}");
        builder.AppendLine();
        builder.AppendLine("Cause groups:");
        foreach (var group in FindingGroups)
        {
            builder.AppendLine($"[{group.Severity} x{group.Occurrences}] {group.Title}");
        }
        return builder.ToString();
    }

    public static int SeverityRank(string severity) => severity.ToUpperInvariant() switch
    {
        "CRITICAL" => 0,
        "HIGH" => 1,
        "MEDIUM" => 2,
        "LOW" => 3,
        _ => 4,
    };
}
