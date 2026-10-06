using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

[Trait("Category", "Database")]
public sealed class MeAndContextTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Me_returns_memberships_and_accessible_branches()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var me = await client.GetFromJsonAsync<MeView>("/api/v1/me");
        Assert.Equal(AlphaAdmin, me!.UserId);
        Assert.Equal(Alpha, me.ActiveTenantId);
        Assert.Contains("tenant_admin", me.Roles);
        Assert.All(me.Memberships, m => Assert.Equal(Alpha, m.TenantId));
        Assert.Contains(me.AccessibleBranches, b => b.Id == AlphaMain);
        Assert.Contains(me.AccessibleBranches, b => b.Id == AlphaEast);
        Assert.DoesNotContain(me.AccessibleBranches, b => b.Id == BetaMain);
    }

    [Fact]
    public async Task Receptionist_sees_only_her_branch()
    {
        using var client = factory.ClientAs(AlphaReception, Alpha);
        var me = await client.GetFromJsonAsync<MeView>("/api/v1/me");
        Assert.Equal([AlphaMain], me!.AccessibleBranches.Select(b => b.Id).ToArray());
    }

    [Fact]
    public async Task Switching_context_is_validated_server_side_and_persisted()
    {
        var user = await CreateUserAsync("switcher", (Alpha, AlphaEast, "doctor"), (Beta, null, "doctor"));
        using var client = factory.ClientAs(user);

        // Not a member of Alpha Main: denied.
        var denied = await client.PostAsJsonAsync("/api/v1/me/context", new { tenantId = Alpha, branchId = AlphaMain });
        Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);

        // A branch of another tenant: denied.
        var mismatched = await client.PostAsJsonAsync("/api/v1/me/context", new { tenantId = Alpha, branchId = BetaMain });
        Assert.Equal(HttpStatusCode.Forbidden, mismatched.StatusCode);

        // A tenant without membership: denied.
        var foreign = await client.PostAsJsonAsync("/api/v1/me/context", new { tenantId = Guid.NewGuid() });
        Assert.Equal(HttpStatusCode.Forbidden, foreign.StatusCode);

        var ok = await client.PostAsJsonAsync("/api/v1/me/context", new { tenantId = Beta, branchId = BetaMain });
        Assert.Equal(HttpStatusCode.NoContent, ok.StatusCode);

        // A token without tenant claim now resolves to the stored context (what the hook would issue next).
        var tenant = await client.GetFromJsonAsync<TenantView>("/api/v1/tenants/current");
        Assert.Equal(Beta, tenant!.Id);
        Assert.Equal(BetaMain, tenant.ActiveBranchId);

        var back = await client.PostAsJsonAsync("/api/v1/me/context", new { tenantId = Alpha, branchId = AlphaEast });
        Assert.Equal(HttpStatusCode.NoContent, back.StatusCode);
        var me = await client.GetFromJsonAsync<MeView>("/api/v1/me");
        Assert.Equal(Alpha, me!.ActiveTenantId);
        Assert.Equal(AlphaEast, me.ActiveBranchId);
        Assert.Equal(2, me.Memberships.Count);
    }

    [Fact]
    public async Task Branch_claim_outside_scope_is_403()
    {
        using var client = factory.ClientAs(AlphaReception, Alpha, AlphaEast);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/api/v1/patients")).StatusCode);
    }
}
