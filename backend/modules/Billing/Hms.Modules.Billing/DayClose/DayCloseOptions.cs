namespace Hms.Modules.Billing.DayClose;

/// <summary>
/// #65: day-end close settings from configuration (DayClose section), not code. Variance reasons are
/// one-tap suggestions (free text is still allowed); method labels are what the desk sees per mode.
/// </summary>
public sealed class DayCloseOptions
{
    public const string Section = "DayClose";

    public List<string> VarianceReasons { get; init; } = [];

    public Dictionary<string, string> MethodLabels { get; init; } = new(StringComparer.Ordinal);

    /// <summary>Longest reason or note accepted (the database enforces the same limit).</summary>
    public int MaxReasonLength { get; init; } = 200;
}
