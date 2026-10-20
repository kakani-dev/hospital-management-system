using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>Cross-tenant attacks through the real HTTP pipeline, real JWT validation, real Postgres + RLS.</summary>
[Trait("Category", "Database")]
public sealed class TenantIsolationApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Alpha_admin_lists_only_alpha_patients()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var page = await client.GetFromJsonAsync<PagedView<PatientView>>("/api/v1/patients?pageSize=100");
        Assert.NotNull(page);
        Assert.NotEmpty(page.Items);
        Assert.DoesNotContain(page.Items, p => p.Mrn.StartsWith("BET-", StringComparison.Ordinal) || p.LastName == "Synthetic-Beta");
    }

    [Fact]
    public async Task Other_tenants_patient_id_is_404_not_403()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync($"/api/v1/patients/{BetaPatientId}")).StatusCode);
    }

    [Fact]
    public async Task Own_patient_is_readable()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var patient = await client.GetFromJsonAsync<PatientView>($"/api/v1/patients/{AlphaPatientId}");
        Assert.Equal("ALP-0001", patient!.Mrn);
    }

    [Fact]
    public async Task Token_claiming_a_tenant_without_membership_is_403()
    {
        // Validly signed token, but the user is not a member of Beta (e.g. stale or forged claim).
        using var client = factory.ClientAs(AlphaAdmin, Beta);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/api/v1/patients")).StatusCode);
    }

    [Fact]
    public async Task Spoofed_tenant_headers_are_ignored()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        client.DefaultRequestHeaders.Add("X-Tenant-Id", Beta.ToString());
        client.DefaultRequestHeaders.Add("X-Branch-Id", BetaMain.ToString());
        var page = await client.GetFromJsonAsync<PagedView<PatientView>>("/api/v1/patients?pageSize=100");
        Assert.DoesNotContain(page!.Items, p => p.LastName == "Synthetic-Beta");
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync($"/api/v1/patients/{BetaPatientId}")).StatusCode);
    }

    [Fact]
    public async Task Spoofed_app_metadata_tenant_claim_does_not_grant_access()
    {
        var claims = new Dictionary<string, object> { ["tenant_id"] = Beta.ToString(), ["app_metadata"] = new Dictionary<string, object> { ["tenant_id"] = Beta.ToString() } };
        using var client = factory.ClientWithToken(TestJwt.Create(Outsider, claims));
        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/api/v1/patients")).StatusCode);
    }

    [Fact]
    public async Task User_without_memberships_has_no_tenant()
    {
        using var client = factory.ClientAs(Outsider);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/api/v1/patients")).StatusCode);
        var me = await client.GetFromJsonAsync<MeView>("/api/v1/me");
        Assert.Empty(me!.Memberships);
        Assert.Null(me.ActiveTenantId);
    }

    [Fact]
    public async Task Missing_tenant_claim_falls_back_to_server_side_default_context()
    {
        using var client = factory.ClientAs(BetaDoctor);
        var tenant = await client.GetFromJsonAsync<TenantView>("/api/v1/tenants/current");
        Assert.Equal(Beta, tenant!.Id);
    }

    [Fact]
    public async Task Patient_registered_in_alpha_gets_alpha_tenant_even_if_body_names_beta_branch()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await client.PostAsJsonAsync("/api/v1/patients", new
        {
            mrn = $"X-{Guid.NewGuid():N}"[..20],
            firstName = "Cross",
            lastName = "Attempt",
            registeredBranchId = BetaMain,
            tenantId = Beta,
        });
        // 404-not-403: another tenant's branch is indistinguishable from an unknown one.
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        Assert.Contains("\"not_found\"", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Receptionist_cannot_register_at_a_branch_outside_scope()
    {
        using var client = factory.ClientAs(AlphaReception, Alpha);
        var response = await client.PostAsJsonAsync("/api/v1/patients", new
        {
            mrn = $"R-{Guid.NewGuid():N}"[..20],
            firstName = "Scope",
            lastName = "Test",
            registeredBranchId = AlphaEast,
        });
        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Fact]
    public async Task Register_patient_gets_a_server_generated_mrn_per_tenant_and_client_mrns_are_ignored()
    {
        var typed = $"T-{Guid.NewGuid():N}"[..20];
        using var alpha = factory.ClientAs(AlphaReception, Alpha);
        var created = await alpha.PostAsJsonAsync("/api/v1/patients", new { mrn = typed, firstName = "New", lastName = "Patient", registeredBranchId = AlphaMain, sex = "female" });
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var patient = await created.Content.ReadFromJsonAsync<PatientView>();
        Assert.Matches("^DEMO-ALPHA-[0-9]{6,}$", patient!.Mrn); // <tenant code>-<counter>, returned in the 201

        var again = await alpha.PostAsJsonAsync("/api/v1/patients", new { mrn = patient.Mrn, firstName = "Dup", lastName = "Patient", registeredBranchId = AlphaMain });
        Assert.Equal(HttpStatusCode.Created, again.StatusCode);
        var second = await again.Content.ReadFromJsonAsync<PatientView>();
        Assert.NotEqual(patient.Mrn, second!.Mrn);

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        var otherTenant = await beta.PostAsJsonAsync("/api/v1/patients", new { mrn = typed, firstName = "Same", lastName = "Mrn", registeredBranchId = BetaMain });
        Assert.Equal(HttpStatusCode.Created, otherTenant.StatusCode);
        Assert.Matches("^DEMO-BETA-[0-9]{6,}$", (await otherTenant.Content.ReadFromJsonAsync<PatientView>())!.Mrn);

        // The MRN is immutable through the API.
        var change = await alpha.PatchAsJsonAsync($"/api/v1/patients/{patient.Id}", new { mrn = "DEMO-ALPHA-999999" });
        Assert.Equal(HttpStatusCode.BadRequest, change.StatusCode);

        // And Beta still cannot see Alpha's new patient.
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync($"/api/v1/patients/{patient.Id}")).StatusCode);
    }

    [Fact]
    public async Task Lab_technician_cannot_read_patient_registry()
    {
        using var client = factory.ClientAs(AlphaLab, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/api/v1/patients")).StatusCode);
    }

    [Fact]
    public async Task Invalid_patient_payload_is_400()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await client.PostAsJsonAsync("/api/v1/patients", new { mrn = "", firstName = "", lastName = "", registeredBranchId = AlphaMain });
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Writer_role_at_one_branch_does_not_allow_writes_at_another()
    {
        // Review M1 / PoC P2: billing (read-only) at Main + nurse at East.
        var user = await CreateUserAsync("mixed", (Alpha, AlphaMain, "billing"), (Alpha, AlphaEast, "receptionist") /* RBAC: nurses no longer write patients */);
        using var client = factory.ClientAs(user, Alpha);
        var atMain = await client.PostAsJsonAsync("/api/v1/patients", new { mrn = $"M-{Guid.NewGuid():N}"[..20], firstName = "Main", lastName = "Branch", registeredBranchId = AlphaMain });
        Assert.Equal(HttpStatusCode.Forbidden, atMain.StatusCode);
        var atEast = await client.PostAsJsonAsync("/api/v1/patients", new { mrn = $"E-{Guid.NewGuid():N}"[..20], firstName = "East", lastName = "Branch", registeredBranchId = AlphaEast });
        Assert.Equal(HttpStatusCode.Created, atEast.StatusCode);
        // Reads stay tenant-wide.
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync($"/api/v1/patients/{AlphaPatientId}")).StatusCode);
    }

    [Fact]
    public async Task Search_is_a_post_body_and_stays_tenant_scoped()
    {
        using var alpha = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await alpha.PostAsJsonAsync("/api/v1/patients/search", new { search = "synthetic", page = 1, pageSize = 100 });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var page = await response.Content.ReadFromJsonAsync<PagedView<PatientView>>();
        Assert.NotEmpty(page!.Items);
        Assert.DoesNotContain(page.Items, p => p.LastName == "Synthetic-Beta");

        Assert.Equal(HttpStatusCode.BadRequest, (await alpha.GetAsync("/api/v1/patients?search=synthetic")).StatusCode);
    }

    [Fact]
    public async Task Responses_carry_the_resolved_tenant()
    {
        using var alpha = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await alpha.GetAsync("/api/v1/patients");
        Assert.Equal(Alpha.ToString(), Assert.Single(response.Headers.GetValues("X-Hms-Tenant")));

        using var beta = factory.ClientAs(BetaDoctor); // resolved from the server-side default
        Assert.Equal(Beta.ToString(), Assert.Single((await beta.GetAsync("/api/v1/tenants/current")).Headers.GetValues("X-Hms-Tenant")));
    }
}
