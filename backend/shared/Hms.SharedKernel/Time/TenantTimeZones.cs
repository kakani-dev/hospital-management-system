using System.Text.RegularExpressions;

namespace Hms.SharedKernel.Time;

// Self-contained (BCL only, no project dependencies) so the microservices work can move it
// into Hms.Platform as-is; only the namespace changes.

/// <summary>
/// Tenant / branch time-zone rules, mirroring the database (migration 20261012090100):
/// every tenant has a REQUIRED IANA zone (identity.tenants.time_zone); a branch may override it
/// (identity.branches.timezone_override, null = inherit). identity.branch_time_zone_v1() and
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
    /// Same rule as identity.is_valid_time_zone(): UTC or Area/City[/Sub] with no digits or '+'
    /// (rejects POSIX suffixes such as Asia/Kolkata+5, which means UTC-5), never the pseudo zones
    /// (localtime = the server zone, posixrules, Factory, posix/*, right/*), no Etc/* except Etc/UTC
    /// (Etc/GMT+5 means UTC-5), and known to this runtime.
    /// Aliases are judged by their canonical name. HasIanaId: on ICU runtimes Windows ids
    /// ("India Standard Time") resolve too, but PostgreSQL only understands IANA names.
    /// </summary>
    public static bool IsValidIana(string? zone)
    {
        if (string.IsNullOrWhiteSpace(zone) || zone.Length > 64 || !Shape().IsMatch(zone)
            || zone is "localtime" or "posixrules" or "Factory"
            || zone.StartsWith("posix/", StringComparison.Ordinal) || zone.StartsWith("right/", StringComparison.Ordinal)
            || (zone.StartsWith("Etc/", StringComparison.Ordinal) && zone != "Etc/UTC"))
        {
            return false;
        }

        var canonical = Canonicalize(zone)!;
        return TimeZoneInfo.TryFindSystemTimeZoneById(canonical, out var tz)
               && tz.HasIanaId
               && string.Equals(tz.Id, canonical, StringComparison.Ordinal);
    }

    // Common rejected spellings -> the canonical id to suggest in the 400 message.
    private static readonly Dictionary<string, string> Suggestions = new(StringComparer.OrdinalIgnoreCase)
    {
        ["GMT"] = "UTC", ["Etc/GMT"] = "UTC", ["Etc/Universal"] = "UTC", ["Etc/Zulu"] = "UTC", ["Etc/Greenwich"] = "UTC",
        ["Universal"] = "UTC", ["Zulu"] = "UTC", ["Greenwich"] = "UTC", ["Z"] = "UTC",
        ["IST"] = "Asia/Kolkata",
        ["US/Eastern"] = "America/New_York", ["US/Central"] = "America/Chicago",
        ["US/Mountain"] = "America/Denver", ["US/Pacific"] = "America/Los_Angeles",
        // Windows ids (InvariantGlobalization=true leaves TryConvertWindowsIdToIanaId without ICU data)
        ["India Standard Time"] = "Asia/Kolkata", ["Arabian Standard Time"] = "Asia/Dubai",
        ["GMT Standard Time"] = "Europe/London", ["W. Europe Standard Time"] = "Europe/Berlin",
        ["Eastern Standard Time"] = "America/New_York", ["Central Standard Time"] = "America/Chicago",
        ["Mountain Standard Time"] = "America/Denver", ["Pacific Standard Time"] = "America/Los_Angeles",
        ["Singapore Standard Time"] = "Asia/Singapore", ["AUS Eastern Standard Time"] = "Australia/Sydney",
        ["Coordinated Universal Time"] = "UTC",
    };

    /// <summary>
    /// The canonical IANA id to suggest for a rejected value (GMT -> UTC, US/Eastern -> America/New_York,
    /// a Windows id -> its IANA id, Asia/Kolkata+5 -> Asia/Kolkata), or null when there is no good guess.
    /// </summary>
    public static string? Suggest(string? zone)
    {
        if (string.IsNullOrWhiteSpace(zone))
        {
            return null;
        }

        var trimmed = zone.Trim();
        if (Suggestions.TryGetValue(trimmed, out var known))
        {
            return known;
        }

        if (IsValidIana(trimmed))
        {
            return Canonicalize(trimmed);
        }

        // POSIX suffix (Asia/Kolkata+5, Asia/Kolkata-05:30): suggest the bare zone
        var cut = trimmed.IndexOfAny(['+', '-'], Math.Max(0, trimmed.IndexOf('/', StringComparison.Ordinal)));
        while (cut > 0 && char.IsLetter(trimmed[cut - 1]) && cut + 1 < trimmed.Length && char.IsLetter(trimmed[cut + 1]))
        {
            cut = trimmed.IndexOfAny(['+', '-'], cut + 1); // hyphenated names such as Port-au-Prince
        }

        if (cut > 0 && IsValidIana(trimmed[..cut]))
        {
            return Canonicalize(trimmed[..cut]);
        }

        return TimeZoneInfo.TryConvertWindowsIdToIanaId(trimmed, out var iana) && IsValidIana(iana) ? Canonicalize(iana) : null;
    }

    [GeneratedRegex("^(UTC|[A-Z][A-Za-z_-]+(/[A-Z][A-Za-z_-]*){1,2})$", RegexOptions.CultureInvariant)]
    private static partial Regex Shape();
}

/// <summary>A day-based rule ran without a tenant/branch zone. Never defaulted (DB review S7): surfaces as a 500.</summary>
public sealed class MissingTimeZoneException()
    : InvalidOperationException("No time zone is known for this tenant/branch; every tenant must have identity.tenants.time_zone.");
