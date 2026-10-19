using Hms.Modules.Identity.Persistence;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Time;
using Microsoft.AspNetCore.Http.HttpResults;

namespace Hms.Modules.Identity.Endpoints;

/// <summary>
/// Zone changes (tenant zone, or a branch override) go through identity.change_time_zone_v1 (DB re-review
/// R5): with future bookings in the affected branches and no confirmation nothing changes and the API
/// answers 409 time_zone_has_future_bookings with the count; the admin repeats with confirmation.
/// </summary>
internal static class TimeZoneChange
{
    public const string FutureBookingsCode = "time_zone_has_future_bookings";
    public const string LockedCode = "time_zone_locked";

    public sealed record Outcome(bool Changed, int FutureBookings, string? TimeZone);

    /// <param name="branchId">null = the tenant zone.</param>
    /// <param name="zone">null on a branch = inherit the tenant zone.</param>
    public static async Task<Outcome> ApplyAsync(
        IdentityDbContext db, Guid tenantId, Guid? branchId, string? zone, bool confirm, CancellationToken ct)
    {
        var rows = await RawSql.QueryAsync(
            db,
            "select changed, future_bookings, time_zone from identity.change_time_zone_v1(@tenant, @branch, @zone::text, @confirm)",
            r => new Outcome(r.GetBoolean(0), r.GetInt32(1), r.IsDBNull(2) ? null : r.GetString(2)),
            ct,
            ("tenant", tenantId),
            ("branch", branchId),
            ("zone", TenantTimeZones.Canonicalize(zone)),
            ("confirm", confirm));
        return rows.Single();
    }

    public static ProblemHttpResult NeedsConfirmation(Outcome outcome) =>
        HmsProblems.Conflict(
            FutureBookingsCode,
            $"{outcome.FutureBookings} future booking(s) would move to a different local time. Repeat the request with confirmFutureBookings = true to change the time zone anyway.",
            new Dictionary<string, object?> { ["futureBookings"] = outcome.FutureBookings });

    public static ProblemHttpResult? FromDatabase(Exception ex) =>
        HmsProblems.FindDbError(ex)?.SqlState == HmsProblems.SqlStates.ObjectNotInPrerequisiteState
            ? HmsProblems.Conflict(LockedCode, "Today's queue already has entries in an affected branch; change the time zone after the day closes.")
            : HmsProblems.FromDatabase(ex);
}
