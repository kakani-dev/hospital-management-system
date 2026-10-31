using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>Owner dashboard KPIs: shape, RBAC, tenant isolation and input guards. Read-only.</summary>
[Trait("Category", "Database")]
public sealed class OwnerKpisApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static string Range(int days)
    {
        var to = DateOnly.FromDateTime(DateTime.UtcNow.AddHours(5.5));
        return $"from={to.AddDays(-(days - 1)):yyyy-MM-dd}&to={to:yyyy-MM-dd}";
    }

    [Fact]
    public async Task Admin_reads_daily_kpis_for_a_week()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var res = await admin.GetAsync($"/api/v1/billing-reports/owner-kpis?{Range(7)}&branchId={AlphaMain}");
        Assert.Equal(HttpStatusCode.OK, res.StatusCode);
        var body = await res.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(7, body.GetProperty("days").GetArrayLength());
        Assert.True(body.GetProperty("totals").TryGetProperty("collectedPaise", out _));
        Assert.Equal(JsonValueKind.Object, body.GetProperty("byMode").ValueKind);
    }

    [Fact]
    public async Task Staff_without_earnings_and_other_tenants_are_refused()
    {
        using var lab = factory.ClientAs(AlphaLab, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.GetAsync($"/api/v1/billing-reports/owner-kpis?{Range(1)}")).StatusCode);
        using var beta = factory.ClientAs(BetaAdmin, Beta, BetaMain);
        var leak = await beta.GetAsync($"/api/v1/billing-reports/owner-kpis?{Range(1)}&branchId={AlphaMain}");
        Assert.Equal(HttpStatusCode.Forbidden, leak.StatusCode);
    }

    [Fact]
    public async Task Bad_ranges_are_rejected()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.GetAsync("/api/v1/billing-reports/owner-kpis?from=x&to=y")).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.GetAsync($"/api/v1/billing-reports/owner-kpis?{Range(120)}")).StatusCode);
    }
}
