using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.AuditTz;

/// <summary>(B) Tenant time zone: create tenant (platform), tenant settings, zone in /me, branch override.</summary>
[Trait("Category", "Database")]
public sealed class TenantTimeZoneApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Create_tenant_requires_a_platform_admin_and_a_valid_zone()
    {
        var body = new { code = ATz.Code(), name = "Synthetic Hospital", timeZone = "Asia/Kolkata" };

        // A tenant admin of another hospital is not a platform admin: 403 from identity.create_tenant().
        using var alphaAdmin = factory.ClientAs(AlphaAdmin, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await alphaAdmin.PostAsJsonAsync("/api/v1/platform/tenants", body)).StatusCode);
        using var anonymous = factory.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await anonymous.PostAsJsonAsync("/api/v1/platform/tenants", body)).StatusCode);

        using var platform = factory.ClientAs(ATz.PlatformAdmin);
        var missing = await platform.PostAsJsonAsync("/api/v1/platform/tenants", new { code = ATz.Code(), name = "No zone" });
        Assert.Equal(HttpStatusCode.BadRequest, missing.StatusCode);
        Assert.Contains("timeZone", await missing.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        Assert.Equal(HttpStatusCode.BadRequest, (await platform.PostAsJsonAsync("/api/v1/platform/tenants", new { code = ATz.Code(), name = "Bad", timeZone = "Mars/Olympus" })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await platform.PostAsJsonAsync("/api/v1/platform/tenants", new { code = ATz.Code(), name = "Windows id", timeZone = "India Standard Time" })).StatusCode);

        Assert.Equal(HttpStatusCode.BadRequest, (await platform.PostAsJsonAsync("/api/v1/platform/tenants", new { code = ATz.Code(), name = "Server zone", timeZone = "localtime" })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await platform.PostAsJsonAsync("/api/v1/platform/tenants", new { code = ATz.Code(), name = "Abbrev", timeZone = "IST" })).StatusCode);

        // A legacy alias (still sent by some browsers) is accepted and stored canonically.
        var alias = await ATz.ReadAsync<ATzCreatedTenant>(
            await platform.PostAsJsonAsync("/api/v1/platform/tenants", new { code = ATz.Code(), name = "Alias", timeZone = "Asia/Calcutta" }), HttpStatusCode.Created);
        Assert.Equal("Asia/Kolkata", alias.TimeZone);
        Assert.Equal("Asia/Kolkata", await ATz.ScalarAsync<string>("select time_zone from identity.tenants where id = @t", ("t", alias.Id)));

        var created = await ATz.ReadAsync<ATzCreatedTenant>(await platform.PostAsJsonAsync("/api/v1/platform/tenants", body), HttpStatusCode.Created);
        Assert.Equal("Asia/Kolkata", created.TimeZone);
        Assert.Equal("Asia/Kolkata", await ATz.ScalarAsync<string>("select time_zone from identity.tenants where id = @t", ("t", created.Id)));
        // default branch inherits (no override) and is attributed to the platform admin
        Assert.Equal(1L, await ATz.ScalarAsync<long>("select count(*) from identity.branches where tenant_id = @t and timezone is null", ("t", created.Id)));
        Assert.Equal(ATz.PlatformAdmin, await ATz.ScalarAsync<Guid>("select created_by from identity.tenants where id = @t", ("t", created.Id)));

        var duplicate = await platform.PostAsJsonAsync("/api/v1/platform/tenants", body);
        Assert.Equal(HttpStatusCode.Conflict, duplicate.StatusCode);
    }

    [Fact]
    public async Task Me_tenant_and_branches_report_the_effective_zone()
    {
        var t = await ATz.NewTenantAsync(factory, "Europe/London");
        using var admin = factory.ClientAs(t.AdminId, t.TenantId);
        var utcBranch = await ATz.CreateBranchAsync(admin, "UTC");
        var inheriting = await ATz.CreateBranchAsync(admin, timezone: null);
        Assert.Equal("Europe/London", inheriting.Timezone);
        Assert.Null(inheriting.TimezoneOverride);
        Assert.Equal("UTC", utcBranch.Timezone);
        Assert.Equal("UTC", utcBranch.TimezoneOverride);

        var tenant = await admin.GetFromJsonAsync<ATzTenant>("/api/v1/tenants/current");
        Assert.Equal("Europe/London", tenant!.TimeZone);

        var me = await admin.GetFromJsonAsync<ATzMe>("/api/v1/me");
        Assert.Equal("Europe/London", me!.TimeZone);
        Assert.Equal("UTC", me.AccessibleBranches.Single(b => b.Id == utcBranch.Id).TimeZone);
        Assert.Equal("Europe/London", me.AccessibleBranches.Single(b => b.Id == t.MainBranchId).TimeZone);

        using var atUtc = factory.ClientAs(t.AdminId, t.TenantId, utcBranch.Id);
        Assert.Equal("UTC", (await atUtc.GetFromJsonAsync<ATzMe>("/api/v1/me"))!.TimeZone);

        // Clearing the override makes the branch follow the tenant zone again.
        var cleared = await ATz.ReadAsync<ATzBranch>(
            await admin.PatchAsJsonAsync($"/api/v1/branches/{utcBranch.Id}", new { inheritTimezone = true }), HttpStatusCode.OK);
        Assert.Equal("Europe/London", cleared.Timezone);
        Assert.Null(cleared.TimezoneOverride);
    }

    [Fact]
    public async Task Tenant_settings_are_admin_only_validated_and_inherited_by_branches()
    {
        var t = await ATz.NewTenantAsync(factory);
        using var admin = factory.ClientAs(t.AdminId, t.TenantId);
        var dubai = await ATz.CreateBranchAsync(admin, "Asia/Dubai");

        var reception = await CreateUserAsync("atz-reception", (t.TenantId, null, "receptionist"));
        using var receptionClient = factory.ClientAs(reception, t.TenantId);
        Assert.Equal(HttpStatusCode.Forbidden, (await receptionClient.PatchAsJsonAsync("/api/v1/tenants/current", new { timeZone = "UTC" })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { timeZone = "Not/AZone" })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { })).StatusCode);

        var updated = await ATz.ReadAsync<ATzTenant>(
            await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { timeZone = "America/New_York", name = "Renamed synthetic" }), HttpStatusCode.OK);
        Assert.Equal("America/New_York", updated.TimeZone);
        Assert.Equal("Renamed synthetic", updated.Name);

        var branches = await admin.GetFromJsonAsync<List<ATzBranch>>("/api/v1/branches");
        Assert.NotNull(branches);
        Assert.Equal("America/New_York", branches.Single(b => b.Id == t.MainBranchId).Timezone); // inherits
        Assert.Equal("Asia/Dubai", branches.Single(b => b.Id == dubai.Id).Timezone);              // override kept
    }

    [Fact]
    public async Task Zone_change_is_refused_while_today_s_queue_has_entries()
    {
        var t = await ATz.NewTenantAsync(factory);
        using var admin = factory.ClientAs(t.AdminId, t.TenantId);
        var patient = await Sprint2.S2.CreatePatientAsync(admin, t.MainBranchId);
        var walkIn = await admin.PostAsJsonAsync("/api/v1/queue/walk-in", new { branchId = t.MainBranchId, patientId = patient.Id });
        Assert.Equal(HttpStatusCode.Created, walkIn.StatusCode);

        var locked = await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { timeZone = "UTC" });
        Assert.Equal(HttpStatusCode.Conflict, locked.StatusCode);
        Assert.Equal("time_zone_locked", await ATz.CodeAsync(locked));
        Assert.Equal("Asia/Kolkata", await ATz.ScalarAsync<string>("select time_zone from identity.tenants where id = @t", ("t", t.TenantId)));

        // Same rule for a branch override at that branch.
        var branchLocked = await admin.PatchAsJsonAsync($"/api/v1/branches/{t.MainBranchId}", new { timezone = "UTC" });
        Assert.Equal(HttpStatusCode.Conflict, branchLocked.StatusCode);

        // A name-only change is fine.
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { name = "Still synthetic" })).StatusCode);
    }
}

/// <summary>
/// Day logic at the midnight–05:30 IST edge with a fixed API clock. 2026-10-09T19:00Z is 00:30 IST on
/// 10 Oct: a branch on the tenant zone (Asia/Kolkata) is already on the 10th, a branch overriding to UTC
/// is still on the 9th.
/// </summary>
[Trait("Category", "Database")]
[Trait("Mode", "in-process-only")] // fixed clock needs in-process hosts
public sealed class ZoneDayEdgeApiTests(FixedClockApiFactory factory) : IClassFixture<FixedClockApiFactory>
{
    private static readonly DateTimeOffset HalfPastMidnightIst = new(2026, 10, 9, 19, 0, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset OneMinuteToMidnightIst = new(2026, 10, 9, 18, 29, 0, TimeSpan.Zero);

    private static async Task<ATzSchedule> CreateScheduleAsync(HttpClient admin, Guid branch, int weekday)
    {
        var practitioner = await ATz.CreatePractitionerAsync(admin);
        return await ATz.ReadAsync<ATzSchedule>(
            await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = practitioner.Id, branchId = branch, weekday, startTime = "09:00", endTime = "12:00", slotMinutes = 15 }),
            HttpStatusCode.Created);
    }

    [Fact]
    public async Task Branch_local_today_follows_the_tenant_zone_or_the_branch_override()
    {
        var t = await ATz.NewTenantAsync(factory, "Asia/Kolkata");
        using var admin = factory.ClientAs(t.AdminId, t.TenantId);
        var utc = await ATz.CreateBranchAsync(admin, "UTC");

        factory.Clock.Now = HalfPastMidnightIst;
        // schedules.valid_from defaults to the branch-local today
        Assert.Equal(new DateOnly(2026, 10, 10), (await CreateScheduleAsync(admin, t.MainBranchId, 1)).ValidFrom);
        Assert.Equal(new DateOnly(2026, 10, 9), (await CreateScheduleAsync(admin, utc.Id, 1)).ValidFrom);

        // date of birth "not in the future" uses the same branch-local today
        var dob = new { mrn = Sprint2.S2.Unique("ATZ-"), firstName = "Edge", lastName = "Case", dateOfBirth = "2026-10-10" };
        var ist = await admin.PostAsJsonAsync("/api/v1/patients", new { dob.mrn, dob.firstName, dob.lastName, dob.dateOfBirth, registeredBranchId = t.MainBranchId });
        Assert.Equal(HttpStatusCode.Created, ist.StatusCode);
        var atUtc = await admin.PostAsJsonAsync("/api/v1/patients", new { mrn = Sprint2.S2.Unique("ATZ-"), dob.firstName, dob.lastName, dob.dateOfBirth, registeredBranchId = utc.Id });
        Assert.Equal(HttpStatusCode.BadRequest, atUtc.StatusCode);
        Assert.Contains("dateOfBirth", await atUtc.Content.ReadAsStringAsync(), StringComparison.Ordinal);

        // one minute before IST midnight both branches are on the 9th
        factory.Clock.Now = OneMinuteToMidnightIst;
        Assert.Equal(new DateOnly(2026, 10, 9), (await CreateScheduleAsync(admin, t.MainBranchId, 2)).ValidFrom);
        Assert.Equal(new DateOnly(2026, 10, 9), (await CreateScheduleAsync(admin, utc.Id, 2)).ValidFrom);
    }

    [Fact]
    public async Task Changing_the_tenant_zone_moves_the_day_of_inheriting_branches_only()
    {
        var t = await ATz.NewTenantAsync(factory, "UTC");
        using var admin = factory.ClientAs(t.AdminId, t.TenantId);
        var ist = await ATz.CreateBranchAsync(admin, "Asia/Kolkata");
        factory.Clock.Now = HalfPastMidnightIst;

        Assert.Equal(new DateOnly(2026, 10, 9), (await CreateScheduleAsync(admin, t.MainBranchId, 3)).ValidFrom);
        Assert.Equal(new DateOnly(2026, 10, 10), (await CreateScheduleAsync(admin, ist.Id, 3)).ValidFrom);

        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { timeZone = "Asia/Kolkata" })).StatusCode);
        // the grant (and its zones) is resolved per request, so the next request sees the new zone
        Assert.Equal(new DateOnly(2026, 10, 10), (await CreateScheduleAsync(admin, t.MainBranchId, 4)).ValidFrom);
    }
}
