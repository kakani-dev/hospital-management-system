using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>Pharmacy barcode scanning: GTIN lookup and one-time link. Tenant comes from the server.</summary>
[Trait("Category", "Database")]
public sealed class InventoryGtinApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Unknown_gtin_resolves_to_no_item_and_bad_shapes_are_refused()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var res = await admin.GetAsync("/api/v1/inventory/gtin/09999999999994");
        Assert.Equal(HttpStatusCode.OK, res.StatusCode);
        var body = await res.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("09999999999994", body.GetProperty("gtin").GetString());
        Assert.Equal(JsonValueKind.Null, body.GetProperty("item").ValueKind);

        Assert.Equal(HttpStatusCode.BadRequest, (await admin.GetAsync("/api/v1/inventory/gtin/123")).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PostAsJsonAsync("/api/v1/inventory/gtin", new { gtin = "12", itemId = Guid.NewGuid() })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PostAsJsonAsync("/api/v1/inventory/gtin", new { gtin = "09999999999994", itemId = Guid.NewGuid() })).StatusCode);
    }

    [Fact]
    public async Task Roles_without_permission_are_refused()
    {
        using var lab = factory.ClientAs(AlphaLab, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.GetAsync("/api/v1/inventory/gtin/09999999999994")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.PostAsJsonAsync("/api/v1/inventory/gtin", new { gtin = "09999999999994", itemId = Guid.NewGuid() })).StatusCode);
    }
}
