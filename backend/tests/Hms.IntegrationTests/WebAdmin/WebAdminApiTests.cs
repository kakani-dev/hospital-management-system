using System.Net;
using System.Net.Http.Json;
using Hms.IntegrationTests.Sprint2;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.WebAdmin;

public sealed record PatientStats(long Total, long RegisteredToday);

public sealed record AdminPractitioner(Guid Id, string DisplayName, bool IsActive, bool IsDeleted);

public sealed record AdminSchedule(Guid Id, Guid PractitionerId, Guid BranchId, int Weekday, bool IsActive, bool IsDeleted);

/// <summary>
/// Endpoints the web admin screens need: GET /patients/stats (dashboard) and includeDeleted on the
/// practitioner and schedule lists (restore). Other test classes write to the same tenant in
/// parallel, so counts are checked as lower bounds.
/// </summary>
[Trait("Category", "Database")]
public sealed class WebAdminApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Patient_stats_count_live_patients_and_todays_registrations_per_branch()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var tenantBefore = (await admin.GetFromJsonAsync<PatientStats>("/api/v1/patients/stats"))!;
        var eastBefore = (await admin.GetFromJsonAsync<PatientStats>($"/api/v1/patients/stats?branchId={AlphaEast}"))!;
        Assert.True(eastBefore.Total <= tenantBefore.Total);
        Assert.True(eastBefore.RegisteredToday <= eastBefore.Total);

        await S2.CreatePatientAsync(admin, AlphaEast);

        var tenantAfter = (await admin.GetFromJsonAsync<PatientStats>("/api/v1/patients/stats"))!;
        var eastAfter = (await admin.GetFromJsonAsync<PatientStats>($"/api/v1/patients/stats?branchId={AlphaEast}"))!;
        Assert.True(tenantAfter.Total >= tenantBefore.Total + 1);
        Assert.True(tenantAfter.RegisteredToday >= tenantBefore.RegisteredToday + 1);
        Assert.True(eastAfter.Total >= eastBefore.Total + 1);
        Assert.True(eastAfter.RegisteredToday >= eastBefore.RegisteredToday + 1);
    }

    [Fact]
    public async Task Patient_stats_are_tenant_scoped_and_role_gated()
    {
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync($"/api/v1/patients/stats?branchId={AlphaMain}")).StatusCode);
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.GetAsync($"/api/v1/patients/stats?branchId={Guid.NewGuid()}")).StatusCode);
        using var lab = factory.ClientAs(AlphaLab, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.GetAsync("/api/v1/patients/stats")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await beta.GetAsync($"/api/v1/patients/stats?branchId={BetaMain}")).StatusCode);
    }

    [Fact]
    public async Task Admins_list_deleted_practitioners_and_schedules_to_restore_them()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await S2.CreatePractitionerAsync(admin);
        var created = await admin.PostAsJsonAsync("/api/v1/schedules", new
        {
            practitionerId = practitioner.Id, branchId = AlphaMain, weekday = 3, startTime = "14:00", endTime = "16:00", slotMinutes = 20, validFrom = "2031-01-01",
        });
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var schedule = (await created.Content.ReadFromJsonAsync<AdminSchedule>())!;

        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync($"/api/v1/schedules/{schedule.Id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync($"/api/v1/practitioners/{practitioner.Id}")).StatusCode);

        var live = (await admin.GetFromJsonAsync<List<AdminPractitioner>>("/api/v1/practitioners?activeOnly=false"))!;
        Assert.DoesNotContain(live, p => p.Id == practitioner.Id);
        var all = (await admin.GetFromJsonAsync<List<AdminPractitioner>>("/api/v1/practitioners?activeOnly=false&includeDeleted=true"))!;
        Assert.True(Assert.Single(all, p => p.Id == practitioner.Id).IsDeleted);
        // live ⊆ all (other tests create practitioners in parallel, so the reverse can race)
        Assert.All(live, l => Assert.Contains(all, p => p.Id == l.Id));

        Assert.Empty((await admin.GetFromJsonAsync<List<AdminSchedule>>($"/api/v1/schedules?practitionerId={practitioner.Id}"))!);
        var deletedSchedules = (await admin.GetFromJsonAsync<List<AdminSchedule>>($"/api/v1/schedules?practitionerId={practitioner.Id}&includeDeleted=true"))!;
        Assert.True(Assert.Single(deletedSchedules).IsDeleted);

        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsync($"/api/v1/practitioners/{practitioner.Id}/restore", null)).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsync($"/api/v1/schedules/{schedule.Id}/restore", null)).StatusCode);
        Assert.False(Assert.Single((await admin.GetFromJsonAsync<List<AdminSchedule>>($"/api/v1/schedules?practitionerId={practitioner.Id}"))!).IsDeleted);
    }

    [Fact]
    public async Task Listing_deleted_rows_is_admin_only_and_never_crosses_tenants()
    {
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.GetAsync("/api/v1/practitioners?includeDeleted=true")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.GetAsync("/api/v1/schedules?includeDeleted=true")).StatusCode);

        using var alpha = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await S2.CreatePractitionerAsync(alpha);
        Assert.Equal(HttpStatusCode.NoContent, (await alpha.DeleteAsync($"/api/v1/practitioners/{practitioner.Id}")).StatusCode);
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        var betaAll = (await beta.GetFromJsonAsync<List<AdminPractitioner>>("/api/v1/practitioners?activeOnly=false&includeDeleted=true"))!;
        Assert.DoesNotContain(betaAll, p => p.Id == practitioner.Id);
    }
}
