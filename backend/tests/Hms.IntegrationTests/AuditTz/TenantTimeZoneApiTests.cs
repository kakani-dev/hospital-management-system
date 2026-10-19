using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.AuditTz;

/// <summary>(B) Tenant time zone: create tenant (platform), tenant settings, zone in /me, branch override.</summary>
[Trait("Category", "Database")]
public sealed class TenantTimeZoneApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task The_monolith_has_no_create_tenant_endpoint_and_the_identity_service_requires_a_platform_admin()
    {
        // code review MIN-5: identity.create_tenant stays in the DB; the HTTP endpoint lives in the identity
        // service only (/api/v1/platform/tenants, Level 1 platform console) and needs identity.is_platform_admin().
        using var alphaAdmin = factory.ClientAs(AlphaAdmin, Alpha);
        var admins = await ATz.ScalarAsync<long>("select count(*) from identity.platform_admins");
        var tenants = await ATz.ScalarAsync<long>("select count(*) from identity.tenants");
        var response = await alphaAdmin.PostAsJsonAsync("/api/v1/platform/tenants", new { code = ATz.Code(), name = "Synthetic", timeZone = "Asia/Kolkata", adminEmail = "x@synthetic.example" });
        if (Target == SystemTarget.Monolith)
        {
            Assert.True(response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.MethodNotAllowed, $"got {(int)response.StatusCode}");
        }
        else
        {
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        }

        Assert.Equal(admins, await ATz.ScalarAsync<long>("select count(*) from identity.platform_admins"));
        Assert.True(await ATz.ScalarAsync<long>("select count(*) from identity.tenants") >= tenants);
        Assert.Equal(0L, await ATz.ScalarAsync<long>("select count(*) from identity.tenants where name = 'Synthetic'"));
    }

    [Fact]
    public async Task Tenant_zone_validation_rejects_pseudo_zones_and_suggests_the_canonical_id()
    {
        var t = await ATz.NewTenantAsync(factory);
        using var admin = factory.ClientAs(t.AdminId, t.TenantId);
        foreach (var bad in new[] { "localtime", "IST", "India Standard Time", "Asia/Kolkata+5", "Etc/GMT+5", "Mars/Olympus" })
        {
            var response = await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { timeZone = bad });
            Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        }

        var posix = await (await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { timeZone = "Asia/Kolkata+5" })).Content.ReadAsStringAsync();
        Assert.Contains("Did you mean 'Asia/Kolkata'?", posix, StringComparison.Ordinal);
        var gmt = await (await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { timeZone = "GMT" })).Content.ReadAsStringAsync();
        Assert.Contains("Did you mean 'UTC'?", gmt, StringComparison.Ordinal);

        // A legacy alias is accepted and stored canonically.
        var alias = await ATz.ReadAsync<ATzTenant>(await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { timeZone = "Asia/Calcutta" }), HttpStatusCode.OK);
        Assert.Equal("Asia/Kolkata", alias.TimeZone);
        Assert.Equal("Asia/Kolkata", await ATz.ScalarAsync<string>("select time_zone from identity.tenants where id = @t", ("t", t.TenantId)));
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
    public async Task Zone_change_with_future_bookings_needs_confirmation()
    {
        // DB re-review R5: schedules are wall-clock; a zone change moves future slots while bookings
        // keep their instant. 409 with the count, then confirmFutureBookings = true proceeds.
        var t = await ATz.NewTenantAsync(factory);
        using var admin = factory.ClientAs(t.AdminId, t.TenantId);
        var practitioner = await ATz.CreatePractitionerAsync(admin);
        var patient = await Sprint2.S2.CreatePatientAsync(admin, t.MainBranchId);
        Assert.Equal(HttpStatusCode.Created,
            (await Sprint2.S2.BookAsync(admin, t.MainBranchId, practitioner.Id, patient.Id, Sprint2.S2.FutureSlot(dayOffset: 30))).StatusCode);

        var unconfirmed = await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { timeZone = "Europe/London", name = "Not saved" });
        Assert.Equal(HttpStatusCode.Conflict, unconfirmed.StatusCode);
        Assert.Equal("time_zone_has_future_bookings", await ATz.CodeAsync(unconfirmed));
        using (var body = System.Text.Json.JsonDocument.Parse(await unconfirmed.Content.ReadAsStringAsync()))
        {
            Assert.Equal(1, body.RootElement.GetProperty("futureBookings").GetInt32());
        }

        Assert.Equal("Asia/Kolkata", await ATz.ScalarAsync<string>("select time_zone from identity.tenants where id = @t", ("t", t.TenantId)));
        Assert.NotEqual("Not saved", await ATz.ScalarAsync<string>("select name from identity.tenants where id = @t", ("t", t.TenantId)));

        var confirmed = await ATz.ReadAsync<ATzTenant>(
            await admin.PatchAsJsonAsync("/api/v1/tenants/current", new { timeZone = "Europe/London", confirmFutureBookings = true }), HttpStatusCode.OK);
        Assert.Equal("Europe/London", confirmed.TimeZone);
        // the legacy branches.timezone mirror follows (code review MAJ-1: old readers see the effective zone)
        Assert.Equal("Europe/London", await ATz.ScalarAsync<string>("select timezone from identity.branches where id = @b", ("b", t.MainBranchId)));

        // Same for a branch override.
        var branchUnconfirmed = await admin.PatchAsJsonAsync($"/api/v1/branches/{t.MainBranchId}", new { timezone = "Asia/Dubai" });
        Assert.Equal(HttpStatusCode.Conflict, branchUnconfirmed.StatusCode);
        Assert.Equal("time_zone_has_future_bookings", await ATz.CodeAsync(branchUnconfirmed));
        var branchConfirmed = await ATz.ReadAsync<ATzBranch>(
            await admin.PatchAsJsonAsync($"/api/v1/branches/{t.MainBranchId}", new { timezone = "Asia/Dubai", confirmFutureBookings = true }), HttpStatusCode.OK);
        Assert.Equal("Asia/Dubai", branchConfirmed.Timezone);
        Assert.Equal("Asia/Dubai", branchConfirmed.TimezoneOverride);
        Assert.Equal("Asia/Dubai", await ATz.ScalarAsync<string>("select timezone from identity.branches where id = @b", ("b", t.MainBranchId)));
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
