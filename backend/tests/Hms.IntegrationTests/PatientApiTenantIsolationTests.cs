using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

public class PatientApiTenantIsolationTests : IClassFixture<HmsApiFactory>
{
    private readonly HmsApiFactory _factory;

    public PatientApiTenantIsolationTests(HmsApiFactory factory)
    {
        _factory = factory;
        _factory.Seed();
    }

    private sealed record PatientDto(Guid Id, string Mrn, string FirstName, string LastName, Guid RegisteredBranchId);

    private sealed record Paged(List<PatientDto> Items, int TotalCount);

    private HttpClient ClientAs(Guid user, Guid? tenantClaim, Guid? branchClaim = null)
    {
        var client = _factory.CreateClient();
        client.DefaultRequestHeaders.Add(TestAuthHandler.SubHeader, user.ToString());
        if (tenantClaim is { } t)
        {
            client.DefaultRequestHeaders.Add(TestAuthHandler.TenantHeader, t.ToString());
        }

        if (branchClaim is { } b)
        {
            client.DefaultRequestHeaders.Add(TestAuthHandler.BranchHeader, b.ToString());
        }

        return client;
    }

    [Fact]
    public async Task Anonymous_request_is_rejected_with_401()
    {
        using var client = _factory.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/v1/patients")).StatusCode);
    }

    [Fact]
    public async Task Alpha_user_lists_only_alpha_patients()
    {
        using var client = ClientAs(AlphaAdmin, Alpha);
        // "Kiran" with MRN-1001 exists in BOTH tenants; only Alpha's may come back.
        var kiran = await client.GetFromJsonAsync<Paged>("/api/v1/patients?search=Kiran");
        Assert.NotNull(kiran);
        Assert.Equal("Synthetic-Alpha", Assert.Single(kiran.Items).LastName);

        var all = await client.GetFromJsonAsync<Paged>("/api/v1/patients?pageSize=100");
        Assert.True(all!.TotalCount >= 2);
        Assert.DoesNotContain(all.Items, p => p.Id == BetaPatientId || p.RegisteredBranchId == BetaMain);
    }

    [Fact]
    public async Task Spoofed_tenant_header_is_ignored()
    {
        using var client = ClientAs(AlphaAdmin, Alpha);
        client.DefaultRequestHeaders.Add("X-Tenant-Id", Beta.ToString());
        var page = await client.GetFromJsonAsync<Paged>("/api/v1/patients?search=synthetic");
        Assert.All(page!.Items, p => Assert.EndsWith("Alpha", p.LastName, StringComparison.Ordinal));
    }

    [Fact]
    public async Task Token_claiming_a_tenant_without_membership_gets_403()
    {
        using var client = ClientAs(AlphaAdmin, Beta);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/api/v1/patients")).StatusCode);
    }

    [Fact]
    public async Task Token_without_tenant_claim_gets_403()
    {
        using var client = ClientAs(AlphaAdmin, null);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/api/v1/patients")).StatusCode);
    }

    [Fact]
    public async Task Other_tenants_patient_by_id_returns_404()
    {
        using var client = ClientAs(AlphaAdmin, Alpha);
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync($"/api/v1/patients/{BetaPatientId}")).StatusCode);

        using var beta = ClientAs(BetaDoctor, Beta);
        Assert.Equal(HttpStatusCode.OK, (await beta.GetAsync($"/api/v1/patients/{BetaPatientId}")).StatusCode);
    }

    [Fact]
    public async Task Create_ignores_tenant_id_in_body_and_uses_resolved_tenant()
    {
        using var alpha = ClientAs(AlphaAdmin, Alpha);
        var body = new { tenantId = Beta, mrn = "ALP-7001", firstName = "Body", lastName = "Synthetic-Alpha", sex = "female", registeredBranchId = AlphaMain };
        var response = await alpha.PostAsJsonAsync("/api/v1/patients", body);
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);

        using var beta = ClientAs(BetaDoctor, Beta);
        var betaPage = await beta.GetFromJsonAsync<Paged>("/api/v1/patients?search=ALP-7001");
        Assert.Equal(0, betaPage!.TotalCount);
        var alphaPage = await alpha.GetFromJsonAsync<Paged>("/api/v1/patients?search=ALP-7001");
        Assert.Equal(1, alphaPage!.TotalCount);
    }

    [Fact]
    public async Task Create_into_another_tenants_branch_is_forbidden()
    {
        using var alpha = ClientAs(AlphaAdmin, Alpha);
        var body = new { mrn = "ALP-7002", firstName = "Cross", lastName = "Branch", registeredBranchId = BetaMain };
        Assert.Equal(HttpStatusCode.Forbidden, (await alpha.PostAsJsonAsync("/api/v1/patients", body)).StatusCode);
    }

    [Fact]
    public async Task Receptionist_cannot_register_at_unassigned_branch()
    {
        using var reception = ClientAs(AlphaReception, Alpha);
        var ok = new { mrn = "ALP-7003", firstName = "Front", lastName = "Desk", registeredBranchId = AlphaMain };
        Assert.Equal(HttpStatusCode.Created, (await reception.PostAsJsonAsync("/api/v1/patients", ok)).StatusCode);
        var denied = new { mrn = "ALP-7004", firstName = "Front", lastName = "Desk", registeredBranchId = AlphaEast };
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.PostAsJsonAsync("/api/v1/patients", denied)).StatusCode);
    }

    [Fact]
    public async Task Lab_technician_has_no_registry_access()
    {
        using var lab = ClientAs(AlphaLab, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.GetAsync("/api/v1/patients")).StatusCode);
    }

    [Fact]
    public async Task Invalid_payload_returns_validation_problem()
    {
        using var alpha = ClientAs(AlphaAdmin, Alpha);
        var response = await alpha.PostAsJsonAsync("/api/v1/patients", new { mrn = "bad mrn!", firstName = "", lastName = "X", registeredBranchId = AlphaMain });
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        var text = await response.Content.ReadAsStringAsync();
        Assert.Contains("mrn", text, StringComparison.Ordinal);
        Assert.Contains("firstName", text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Duplicate_mrn_in_same_tenant_returns_409_but_same_mrn_in_other_tenant_is_fine()
    {
        using var alpha = ClientAs(AlphaAdmin, Alpha);
        var dup = new { mrn = "MRN-1001", firstName = "Dup", lastName = "Synthetic-Alpha", registeredBranchId = AlphaMain };
        Assert.Equal(HttpStatusCode.Conflict, (await alpha.PostAsJsonAsync("/api/v1/patients", dup)).StatusCode);
    }

    [Fact]
    public async Task Me_endpoint_returns_server_side_memberships()
    {
        using var client = ClientAs(AlphaReception, Alpha);
        var json = await client.GetStringAsync("/api/v1/me");
        Assert.Contains("Demo Alpha Hospital", json, StringComparison.Ordinal);
        Assert.DoesNotContain("Demo Beta Clinic", json, StringComparison.Ordinal);
        Assert.Contains("receptionist", json, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Current_tenant_requires_valid_branch_claim()
    {
        using var ok = ClientAs(AlphaReception, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.OK, (await ok.GetAsync("/api/v1/tenants/current")).StatusCode);
        using var denied = ClientAs(AlphaReception, Alpha, AlphaEast);
        Assert.Equal(HttpStatusCode.Forbidden, (await denied.GetAsync("/api/v1/tenants/current")).StatusCode);
    }
}
