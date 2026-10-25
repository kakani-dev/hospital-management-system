using Hms.SharedKernel.Tenancy;
using Hms.SharedKernel.Time;

namespace Hms.UnitTests;

/// <summary>Tenant zone is the default; a branch may override it (mirrors identity.branch_time_zone()).</summary>
public class TenantTimeZonesTests
{
    [Theory]
    [InlineData(null, "Europe/London", "Europe/London")]
    [InlineData("", "Europe/London", "Europe/London")]
    [InlineData("UTC", "Asia/Kolkata", "UTC")]
    public void Effective_zone_is_override_else_tenant(string? branchOverride, string? tenantZone, string expected) =>
        Assert.Equal(expected, TenantTimeZones.Effective(branchOverride, tenantZone));

    [Fact]
    public void A_missing_zone_fails_loudly_instead_of_defaulting()
    {
        Assert.Throws<MissingTimeZoneException>(() => TenantTimeZones.Effective(null, null));
        Assert.Throws<MissingTimeZoneException>(() => BranchTime.Today(TimeProvider.System, null));
        Assert.Throws<InvalidOperationException>(() => BranchTime.Today(TimeProvider.System, "Mars/Olympus"));

        var context = new TenantContext();
        var branch = Guid.NewGuid();
        context.Resolve(Guid.NewGuid(), Guid.NewGuid(), branch, ["tenant_admin"], [branch]);
        Assert.Throws<MissingTimeZoneException>(() => context.TenantTimeZone);
        Assert.Throws<MissingTimeZoneException>(() => context.TimeZoneFor(branch));
    }

    [Theory]
    [InlineData("Asia/Calcutta", "Asia/Kolkata")]
    [InlineData("Etc/UTC", "UTC")]
    [InlineData("Asia/Kolkata", "Asia/Kolkata")]
    [InlineData(null, null)]
    public void Legacy_aliases_are_canonicalised(string? zone, string? expected) =>
        Assert.Equal(expected, TenantTimeZones.Canonicalize(zone));

    [Theory]
    [InlineData("Asia/Kolkata", true)]
    [InlineData("UTC", true)]
    [InlineData("Asia/Calcutta", true)]
    [InlineData("India Standard Time", false)]
    [InlineData("localtime", false)]
    [InlineData("posixrules", false)]
    [InlineData("Factory", false)]
    [InlineData("posix/Asia/Kolkata", false)]
    [InlineData("right/UTC", false)]
    [InlineData("IST", false)]
    [InlineData("Mars/Olympus", false)]
    [InlineData("Asia/Kolkata+5", false)]      // code review MIN-2: POSIX suffix = UTC-5
    [InlineData("Asia/Kolkata-05:30", false)]
    [InlineData("UTC+5", false)]
    [InlineData("Etc/GMT+5", false)]           // re-review N3: inverted sign
    [InlineData("Etc/GMT-14", false)]
    [InlineData("Etc/UTC", true)]
    [InlineData("America/Port-au-Prince", true)]
    [InlineData("America/North_Dakota/New_Salem", true)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void Only_iana_ids_are_valid(string? zone, bool valid) => Assert.Equal(valid, TenantTimeZones.IsValidIana(zone));

    [Theory]
    [InlineData("Asia/Kolkata+5", "Asia/Kolkata")]
    [InlineData("Asia/Kolkata-05:30", "Asia/Kolkata")]
    [InlineData("GMT", "UTC")]
    [InlineData("Etc/GMT", "UTC")]
    [InlineData("IST", "Asia/Kolkata")]
    [InlineData("US/Eastern", "America/New_York")]
    [InlineData("Asia/Calcutta", "Asia/Kolkata")]
    [InlineData("Mars/Olympus", null)]
    [InlineData(null, null)]
    public void Rejected_zones_get_a_canonical_suggestion(string? zone, string? expected) =>
        Assert.Equal(expected, TenantTimeZones.Suggest(zone));

    [Fact]
    public void A_windows_id_suggests_its_iana_id() =>
        Assert.Equal("Asia/Kolkata", TenantTimeZones.Suggest("India Standard Time"));

    [Fact]
    public void Tenant_context_falls_back_to_the_tenant_zone_for_branches_without_an_override()
    {
        var main = Guid.NewGuid();
        var utc = Guid.NewGuid();
        var context = new TenantContext();
        context.Resolve(Guid.NewGuid(), Guid.NewGuid(), main, ["tenant_admin"], [main, utc],
            branchTimeZones: new Dictionary<Guid, string> { [utc] = "UTC" }, tenantTimeZone: "Europe/London");
        Assert.Equal("Europe/London", context.TenantTimeZone);
        Assert.Equal("Europe/London", context.TimeZoneFor(main));
        Assert.Equal("UTC", context.TimeZoneFor(utc));
        Assert.Equal("Europe/London", context.TimeZoneFor(null));
    }

    [Fact]
    public void Midnight_to_0530_ist_is_already_the_next_day_in_india_but_not_in_utc()
    {
        var at = new DateTimeOffset(2026, 10, 9, 19, 0, 0, TimeSpan.Zero); // 00:30 IST on 10 Oct
        Assert.Equal(new DateOnly(2026, 10, 10), BranchTime.LocalDate(at, TenantTimeZones.Effective(null, "Asia/Kolkata")));
        Assert.Equal(new DateOnly(2026, 10, 9), BranchTime.LocalDate(at, TenantTimeZones.Effective("UTC", "Asia/Kolkata")));
    }

    [Fact]
    public void Ist_midnight_boundary_moves_today_and_the_utc_day_window()
    {
        var zone = "Asia/Kolkata";
        var before = new DateTimeOffset(2026, 10, 9, 18, 29, 59, TimeSpan.Zero);
        var after = new DateTimeOffset(2026, 10, 9, 18, 30, 1, TimeSpan.Zero);
        Assert.Equal(new DateOnly(2026, 10, 9), BranchTime.LocalDate(before, zone));
        Assert.Equal(new DateOnly(2026, 10, 10), BranchTime.LocalDate(after, zone));

        var ninth = BranchTime.DayRangeUtc(new DateOnly(2026, 10, 9), zone);
        var tenth = BranchTime.DayRangeUtc(new DateOnly(2026, 10, 10), zone);
        Assert.True(before >= ninth.StartUtc && before < ninth.EndUtc);
        Assert.True(after >= tenth.StartUtc && after < tenth.EndUtc);
        Assert.Equal(ninth.EndUtc, tenth.StartUtc);
    }
}
