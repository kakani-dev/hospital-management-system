namespace Hms.Modules.Patients.Endpoints;

/// <summary>Computes "today" in a branch's IANA time zone (falls back to UTC when unknown/invalid).</summary>
public static class BranchClock
{
    public static DateOnly Today(TimeProvider timeProvider, string? ianaTimeZone)
    {
        var utcNow = timeProvider.GetUtcNow();
        if (string.IsNullOrWhiteSpace(ianaTimeZone) || !TimeZoneInfo.TryFindSystemTimeZoneById(ianaTimeZone, out var tz))
        {
            return DateOnly.FromDateTime(utcNow.UtcDateTime);
        }

        return DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(utcNow, tz).DateTime);
    }
}
