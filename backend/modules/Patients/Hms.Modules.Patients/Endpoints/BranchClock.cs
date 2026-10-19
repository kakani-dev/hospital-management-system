using Hms.SharedKernel.Time;

namespace Hms.Modules.Patients.Endpoints;

/// <summary>Computes "today" in a branch's IANA time zone. No UTC fallback: a missing zone throws MissingTimeZoneException, an unknown one InvalidOperationException (see BranchTime.Zone).</summary>
public static class BranchClock
{
    public static DateOnly Today(TimeProvider timeProvider, string? ianaTimeZone) => BranchTime.Today(timeProvider, ianaTimeZone);
}
