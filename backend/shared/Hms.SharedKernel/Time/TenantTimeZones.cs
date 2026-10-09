using System.Text.RegularExpressions;

namespace Hms.SharedKernel.Time;

// Self-contained (BCL only, no project dependencies) so the microservices work can move it
// into Hms.Platform as-is; only the namespace changes.

/// <summary>
/// Tenant / branch time-zone rules, mirroring the database (migration 20261012090100):
/// every tenant has a REQUIRED IANA zone (identity.tenants.time_zone); a branch may override it
/// (identity.branches.timezone, null = inherit). identity.branch_time_zone_v1() and
/// identity.branch_local_date_v1() are the SQL counterparts of <see cref="Effective"/> and
/// <see cref="BranchTime.Today"/>. Every day-based rule (queue day, schedule valid_from,
/// slot "from", date-of-birth "not in the future") uses the EFFECTIVE branch zone.
/// There is deliberately NO default zone: a missing zone is a bug and fails loudly.
/// </summary>
public static partial class TenantTimeZones
{
    // Legacy IANA aliases -> canonical names (identity.canonical_time_zone() in the database).
    private static readonly Dictionary<string, string> Aliases = new(StringComparer.Ordinal)
    {
        ["Asia/Calcutta"] = "Asia/Kolkata",
        ["Asia/Saigon"] = "Asia/Ho_Chi_Minh",
        ["Asia/Katmandu"] = "Asia/Kathmandu",
        ["Asia/Rangoon"] = "Asia/Yangon",
        ["Asia/Dacca"] = "Asia/Dhaka",
        ["Asia/Thimbu"] = "Asia/Thimphu",
        ["America/Buenos_Aires"] = "America/Argentina/Buenos_Aires",
        ["Etc/UTC"] = "UTC",
    };

    /// <summary>The branch override when set, otherwise the tenant zone. Throws when neither is known.</summary>
    public static string Effective(string? branchOverride, string? tenantZone) =>
        !string.IsNullOrWhiteSpace(branchOverride) ? branchOverride
        : !string.IsNullOrWhiteSpace(tenantZone) ? tenantZone
        : throw new MissingTimeZoneException();

    /// <summary>Canonical spelling of a zone id (legacy aliases such as Asia/Calcutta map to Asia/Kolkata).</summary>
    public static string? Canonicalize(string? zone) =>
        zone is not null && Aliases.TryGetValue(zone, out var canonical) ? canonical : zone;

    /// <summary>
    /// Same rule as identity.is_valid_time_zone(): UTC or Area/City[/Sub], never the pseudo zones
    /// (localtime = the server zone, posixrules, Factory, posix/*, right/*), and known to this runtime.
    /// Aliases are judged by their canonical name. HasIanaId: on ICU runtimes Windows ids
    /// ("India Standard Time") resolve too, but PostgreSQL only understands IANA names.
    /// </summary>
    public static bool IsValidIana(string? zone)
    {
        if (string.IsNullOrWhiteSpace(zone) || zone.Length > 64 || !Shape().IsMatch(zone)
            || zone is "localtime" or "posixrules" or "Factory"
            || zone.StartsWith("posix/", StringComparison.Ordinal) || zone.StartsWith("right/", StringComparison.Ordinal))
        {
            return false;
        }

        var canonical = Canonicalize(zone)!;
        return TimeZoneInfo.TryFindSystemTimeZoneById(canonical, out var tz)
               && tz.HasIanaId
               && string.Equals(tz.Id, canonical, StringComparison.Ordinal);
    }

    [GeneratedRegex("^(UTC|[A-Z][A-Za-z_-]+(/[A-Za-z0-9_+-]+){1,2})$", RegexOptions.CultureInvariant)]
    private static partial Regex Shape();
}

/// <summary>A day-based rule ran without a tenant/branch zone. Never defaulted (DB review S7): surfaces as a 500.</summary>
public sealed class MissingTimeZoneException()
    : InvalidOperationException("No time zone is known for this tenant/branch; every tenant must have identity.tenants.time_zone.");
