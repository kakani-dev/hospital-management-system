using Hms.SharedKernel.Time;

namespace Hms.Modules.Billing.Endpoints;

/// <summary>
/// Parses the earnings query. A client tenant id is not a parameter. Whitespace is trimmed.
/// An Indian financial year (April–March) wins over from/to. An empty request is the current
/// calendar month in the hospital time zone.
/// </summary>
internal static class EarningsQuery
{
    internal const int MaxInclusiveDays = 400;

    internal sealed record Parsed(
        DateOnly? From,
        DateOnly? To,
        Guid? BranchId,
        string? Grain,
        int? FinancialYear,
        int? Quarter,
        string CacheKey);

    internal static (Parsed? Value, string? Error) Parse(
        IReadOnlyDictionary<string, string?> query, string timeZone, TimeProvider clock)
    {
        var fromText = Trim(query, "from");
        var toText = Trim(query, "to");
        var grainText = Trim(query, "grain");
        var fyText = Trim(query, "fy");
        var quarterText = Trim(query, "quarter");
        var branchText = Trim(query, "branchId");

        DateOnly? from = null;
        DateOnly? to = null;
        if (fromText is not null)
        {
            if (!DateOnly.TryParseExact(fromText, "yyyy-MM-dd", out var parsedFrom))
            {
                return (null, "from must be a date (yyyy-MM-dd).");
            }

            from = parsedFrom;
        }

        if (toText is not null)
        {
            if (!DateOnly.TryParseExact(toText, "yyyy-MM-dd", out var parsedTo))
            {
                return (null, "to must be a date (yyyy-MM-dd).");
            }

            to = parsedTo;
        }

        int? fy = null;
        if (fyText is not null)
        {
            if (!int.TryParse(fyText, out var parsedFy) || parsedFy is < 2000 or > 2100)
            {
                return (null, "fy must be a financial year from 2000 to 2100.");
            }

            fy = parsedFy;
        }

        int? quarter = null;
        if (quarterText is not null)
        {
            if (!int.TryParse(quarterText, out var parsedQuarter) || parsedQuarter is < 1 or > 4)
            {
                return (null, "quarter must be 1, 2, 3 or 4.");
            }

            if (fy is null)
            {
                return (null, "quarter needs a financial year.");
            }

            quarter = parsedQuarter;
        }

        Guid? branch = null;
        if (branchText is not null)
        {
            if (!Guid.TryParse(branchText, out var parsedBranch) || parsedBranch == Guid.Empty)
            {
                return (null, "branchId must be a branch id.");
            }

            branch = parsedBranch;
        }

        string? grain = null;
        if (grainText is not null)
        {
            grain = grainText.ToLowerInvariant();
            if (grain is not ("day" or "week" or "month"))
            {
                return (null, "grain must be day, week or month.");
            }
        }

        if (fy is null)
        {
            if (from is null && to is null)
            {
                var today = BranchTime.Today(clock, timeZone);
                from = new DateOnly(today.Year, today.Month, 1);
                to = today;
            }
            else if (from is null || to is null)
            {
                return (null, "from and to are both required.");
            }
            else if (to < from)
            {
                return (null, "to is before from.");
            }
            else if (to.Value.DayNumber - from.Value.DayNumber + 1 > MaxInclusiveDays)
            {
                return (null, "the period is longer than 400 days.");
            }
        }

        var key = $"{fy?.ToString() ?? ""}|{quarter?.ToString() ?? ""}|{from:yyyy-MM-dd}|{to:yyyy-MM-dd}|{(branch.HasValue ? branch.Value.ToString("N") : "")}|{grain ?? ""}";
        return (new Parsed(fy is null ? from : null, fy is null ? to : null, branch, grain, fy, quarter, key), null);
    }

    private static string? Trim(IReadOnlyDictionary<string, string?> query, string name)
    {
        if (!query.TryGetValue(name, out var value) || value is null)
        {
            return null;
        }

        var trimmed = value.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }
}
