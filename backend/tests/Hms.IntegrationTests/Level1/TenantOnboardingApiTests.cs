using System.Net;
using System.Net.Http.Json;
using Hms.IntegrationTests.AuditTz;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Level1;

/// <summary>New tenant support: one-screen onboarding with branches + config-seeded defaults, and isolation.</summary>
[Trait("Category", "Database")]
public sealed class TenantOnboardingApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Operator_onboards_a_hospital_with_branches_and_defaults_and_other_tenants_cannot_reach_it()
    {
        using var op = factory.ClientAs(PlatformConsoleApiTests.Operator);
        var bad = await op.PostAsJsonAsync("/api/v1/platform/tenants", new
        {
            code = ATz.Code("zzob"), name = "Zz-QA Onboard (synthetic)", timeZone = "Asia/Kolkata", adminEmail = "zz-qa@onboard.example",
            branches = new[] { new { code = "main", name = "Main", address = (string?)null }, new { code = "main", name = "Other", address = (string?)null } },
        });
        Assert.Equal(HttpStatusCode.BadRequest, bad.StatusCode);
        Assert.Contains("\"branches\"", await bad.Content.ReadAsStringAsync(), StringComparison.Ordinal);

        var code = ATz.Code("zzob");
        var created = await ATz.ReadAsync<L1Approved>(await op.PostAsJsonAsync("/api/v1/platform/tenants", new
        {
            code, name = "Zz-QA Onboard (synthetic)", timeZone = "Asia/Kolkata", adminEmail = "zz-qa@onboard.example",
            branches = new[]
            {
                new { code = "hyd-main", name = "Hyderabad Main", address = (string?)"Synthetic Rd 1" },
                new { code = "blr", name = "Bengaluru", address = (string?)null },
            },
        }), HttpStatusCode.Created);
        var tenant = (await op.GetFromJsonAsync<List<L1Tenant>>($"/api/v1/platform/tenants?search={code}"))!.Single();
        Assert.Equal((2L, 1L), (tenant.BranchCount, tenant.PendingInvites));
        Assert.Equal(1L, await ATz.ScalarAsync<long>("select count(*) from pharmacy.tenant_setting where tenant_id = @t", ("t", created.TenantId)));
        Assert.Equal(1L, await ATz.ScalarAsync<long>("select count(*) from billing.approval_settings where tenant_id = @t", ("t", created.TenantId)));

        // The tenant comes from the caller's memberships server-side; naming another tenant gets nothing.
        using var alpha = factory.ClientAs(AlphaAdmin, created.TenantId);
        Assert.Equal(HttpStatusCode.Forbidden, (await alpha.GetAsync("/api/v1/tenants/current")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await alpha.GetAsync("/api/v1/branches")).StatusCode);
    }
}
