using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>Pharmacy stock and expiry alerts: shape, RBAC, and input guards. Writes nothing.</summary>
[Trait("Category", "Database")]
public sealed class InventoryStockAlertsApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Admin_reads_alerts_and_settings_for_own_tenant()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var res = await admin.GetAsync($"/api/v1/inventory/stock/alerts?branchId={AlphaMain}");
        Assert.Equal(HttpStatusCode.OK, res.StatusCode);
        var body = await res.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(JsonValueKind.Array, body.GetProperty("lowStock").ValueKind);
        Assert.Equal(JsonValueKind.Array, body.GetProperty("expiry").ValueKind);
        Assert.True(body.GetProperty("nearExpiryDays").GetInt32() is >= 1 and <= 365);

        var settings = await admin.GetFromJsonAsync<JsonElement>("/api/v1/inventory/settings");
        Assert.True(settings.TryGetProperty("nearExpiryDays", out _));
    }

    [Fact]
    public async Task Roles_without_permission_are_refused()
    {
        using var lab = factory.ClientAs(AlphaLab, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.GetAsync("/api/v1/inventory/stock/alerts")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.PutAsJsonAsync("/api/v1/inventory/settings", new { nearExpiryDays = 30 })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.PutAsJsonAsync(
            $"/api/v1/inventory/stores/{Guid.NewGuid()}/items/{Guid.NewGuid()}/reorder", new { reorderLevel = 5 })).StatusCode);
    }

    [Fact]
    public async Task Bad_inputs_are_rejected_without_writing()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PutAsJsonAsync("/api/v1/inventory/settings", new { nearExpiryDays = 0 })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PutAsJsonAsync("/api/v1/inventory/settings", new { nearExpiryDays = "ten" })).StatusCode);
        var unknown = await admin.PutAsJsonAsync(
            $"/api/v1/inventory/stores/{Guid.NewGuid()}/items/{Guid.NewGuid()}/reorder", new { reorderLevel = 5 });
        Assert.Equal(HttpStatusCode.NotFound, unknown.StatusCode);
    }
}
