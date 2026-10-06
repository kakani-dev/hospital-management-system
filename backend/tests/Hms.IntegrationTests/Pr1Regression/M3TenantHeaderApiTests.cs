using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Pr1Regression;

/// <summary>
/// PR #1 review finding M3 (API half): the SPA could not notice that its tenant changed underneath
/// it. Contract (FIX-PLAN.md): responses carry X-Hms-Tenant: &lt;resolved tenant id&gt;, which the
/// web app compares against the displayed tenant (E2E half: tests/playwright/e2e/m3-*.spec.ts).
/// </summary>
[Trait("Category", "Database")]
public sealed class M3TenantHeaderApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static string? TenantHeader(HttpResponseMessage response) =>
        response.Headers.TryGetValues(Pr1Contract.TenantHeader, out var values) ? values.Single() : null;

    [Theory]
    [InlineData("/api/v1/me")]
    [InlineData("/api/v1/tenants/current")]
    [InlineData("/api/v1/patients")]
    [InlineData("/api/v1/branches")]
    public async Task M3_responses_carry_X_Hms_Tenant_of_the_resolved_tenant(string path)
    {
        var user = await CreateUserAsync("m3-header", (Alpha, AlphaEast, "doctor"), (Beta, null, "doctor"));

        using var alpha = factory.ClientAs(user, Alpha);
        var a = await alpha.GetAsync(path);
        Assert.Equal(HttpStatusCode.OK, a.StatusCode);
        Assert.Equal(Alpha.ToString(), TenantHeader(a), ignoreCase: true);

        using var beta = factory.ClientAs(user, Beta);
        var b = await beta.GetAsync(path);
        Assert.Equal(HttpStatusCode.OK, b.StatusCode);
        Assert.Equal(Beta.ToString(), TenantHeader(b), ignoreCase: true);
    }

    [Fact]
    public async Task M3_X_Hms_Tenant_follows_a_server_side_switch_made_elsewhere()
    {
        // Tab/device A holds a token without a tenant claim (hook not enabled => server fallback);
        // tab/device B switches the user's context. A's next response must reveal the new tenant.
        var user = await CreateUserAsync("m3-switch", (Alpha, AlphaEast, "doctor"), (Beta, null, "doctor"));
        using var tabA = factory.ClientAs(user);
        using var tabB = factory.ClientAs(user);

        var first = await tabA.GetAsync("/api/v1/patients");
        Assert.Equal(HttpStatusCode.OK, first.StatusCode);
        var initial = Guid.Parse(TenantHeader(first)!);
        var other = initial == Alpha ? Beta : Alpha;

        var switched = await tabB.PostAsJsonAsync("/api/v1/me/context", new { tenantId = other });
        Assert.Equal(HttpStatusCode.NoContent, switched.StatusCode);

        var next = await tabA.GetAsync("/api/v1/patients");
        Assert.Equal(HttpStatusCode.OK, next.StatusCode);
        Assert.Equal(other.ToString(), TenantHeader(next), ignoreCase: true);
    }
}
