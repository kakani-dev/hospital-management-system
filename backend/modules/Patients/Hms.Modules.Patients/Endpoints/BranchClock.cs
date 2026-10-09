using Hms.SharedKernel.Time;

namespace Hms.Modules.Patients.Endpoints;

/// <summary>Computes "today" in a branch's IANA time zone (falls back to UTC when unknown/invalid).</summary>
public static class BranchClock
{
    public static DateOnly Today(TimeProvider timeProvider, string? ianaTimeZone) => BranchTime.Today(timeProvider, ianaTimeZone);
}
