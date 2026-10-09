namespace Hms.SharedKernel.Time;

/// <summary>
/// Branch-local calendar helpers. Zones are IANA ids: the branch override or the tenant zone
/// (ITenantContext.TimeZoneFor). There is no fallback: a missing or unknown zone throws
/// (DB review S7) instead of silently computing "today" in some other zone.
/// </summary>
public static class BranchTime
{
    public static TimeZoneInfo Zone(string? ianaTimeZone)
    {
        if (string.IsNullOrWhiteSpace(ianaTimeZone))
        {
            throw new MissingTimeZoneException();
        }

        return TimeZoneInfo.TryFindSystemTimeZoneById(TenantTimeZones.Canonicalize(ianaTimeZone)!, out var tz)
            ? tz
            : throw new InvalidOperationException($"Unknown IANA time zone '{ianaTimeZone}'.");
    }

    /// <summary>"Today" in the branch's time zone.</summary>
    public static DateOnly Today(TimeProvider timeProvider, string? ianaTimeZone) => LocalDate(timeProvider.GetUtcNow(), ianaTimeZone);

    /// <summary>The branch-local calendar date of an instant.</summary>
    public static DateOnly LocalDate(DateTimeOffset instant, string? ianaTimeZone) =>
        DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(instant, Zone(ianaTimeZone)).DateTime);

    /// <summary>The UTC half-open range [start, end) covering a branch-local calendar day (DST-safe).</summary>
    public static (DateTimeOffset StartUtc, DateTimeOffset EndUtc) DayRangeUtc(DateOnly date, string? ianaTimeZone)
    {
        var zone = Zone(ianaTimeZone);
        return (ToUtc(date.ToDateTime(TimeOnly.MinValue), zone), ToUtc(date.AddDays(1).ToDateTime(TimeOnly.MinValue), zone));
    }

    private static DateTimeOffset ToUtc(DateTime local, TimeZoneInfo zone)
    {
        // Midnight can fall into a DST gap in a few zones: move forward to the first valid instant.
        while (zone.IsInvalidTime(local))
        {
            local = local.AddMinutes(30);
        }

        return new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(local, DateTimeKind.Unspecified), zone), TimeSpan.Zero);
    }
}
