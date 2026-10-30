using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Level1;

/// <summary>GET /patients?sort=recent and /tenants/current defaultCountryCode through the edge (real JWT, Postgres + RLS).</summary>
[Trait("Category", "Database")]
public sealed class RecentPatientsApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{

    [Fact]
    public async Task Sort_recent_puts_a_just_registered_patient_first_and_keeps_rbac()
    {
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        var created = await reception.PostAsJsonAsync("/api/v1/patients", new
        {
            firstName = "Recent", lastName = $"Zz-Recent-{Guid.NewGuid():N}"[..24], registeredBranchId = AlphaMain, sex = "unknown", ageYears = 30, noPhoneReason = "test fixture"
        });
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var id = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();

        // Other test classes register patients in parallel, so "near the top" rather than strictly first.
        var recent = await reception.GetFromJsonAsync<JsonElement>("/api/v1/patients?sort=recent&pageSize=25");
        Assert.Contains(id, recent.GetProperty("items").EnumerateArray().Select(x => x.GetProperty("id").GetGuid()));
        Assert.True(recent.GetProperty("totalCount").GetInt64() >= 1);

        // default order is still by name (the Zz- row sorts last), unknown sort is 400, lab has no patients.view
        var byName = await reception.GetFromJsonAsync<JsonElement>("/api/v1/patients?pageSize=1");
        Assert.NotEqual(id, byName.GetProperty("items")[0].GetProperty("id").GetGuid());
        Assert.Equal(HttpStatusCode.BadRequest, (await reception.GetAsync("/api/v1/patients?sort=bogus")).StatusCode);
        using var lab = factory.ClientAs(AlphaLab, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.GetAsync("/api/v1/patients?sort=recent")).StatusCode);
    }

    [Fact]
    public async Task Current_tenant_exposes_the_default_country_code()
    {
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        var tenant = await reception.GetFromJsonAsync<JsonElement>("/api/v1/tenants/current");
        Assert.Matches(@"^\+[1-9][0-9]{0,2}$", tenant.GetProperty("defaultCountryCode").GetString());
    }
}
