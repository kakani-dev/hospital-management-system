using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>
/// #74 / REG-043, REG-044: inventory negative, RBAC and cross-tenant cases.
/// Nothing here is allowed to write a row, so item/store numbering in InventoryApiTests stays stable.
/// </summary>
[Trait("Category", "Database")]
public sealed class InventoryGuardsApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static object Drug(string brand) => new
    {
        itemKind = "drug", brandName = brand, genericName = "Paracetamol", strength = "500 mg", dosageForm = "tablet",
        hsnCode = "30049099", gstRateBp = 1200, baseUomCode = "TAB",
    };

    [Fact]
    public async Task Roles_without_catalog_permission_cannot_create_items_or_stores()
    {
        using var lab = factory.ClientAs(AlphaLab, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.Forbidden, (await Post(lab, "/api/v1/inventory/items", Drug("Zz guard"))).Status);
        Assert.Equal(HttpStatusCode.Forbidden, (await Post(lab, "/api/v1/inventory/stores", new
        {
            branchId = AlphaMain, name = "Zz guard", storeKind = "op_pharmacy", drugLicenceNo = "DL-9", licenceValidTo = TestDates.YearsAhead(4),
        })).Status);
        Assert.Equal(HttpStatusCode.Forbidden, (await Post(lab, "/api/v1/inventory/opening-stock", new
        {
            storeId = Guid.NewGuid(), lines = new[] { new { itemId = Guid.NewGuid(), batchNo = "B", expiryDate = TestDates.YearsAhead(4, 150), mrpPaise = 100, purchaseRatePaise = 50, qtyBase = 1 } },
        }, Guid.NewGuid())).Status);
    }

    [Fact]
    public async Task Invalid_item_payloads_are_rejected()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.BadRequest, (await Post(admin, "/api/v1/inventory/items", new { itemKind = "drug" })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await Post(admin, "/api/v1/inventory/items", new
        {
            itemKind = "drug", brandName = "Zz guard", genericName = "P", baseUomCode = "TAB", gstRateBp = 1234,
        })).Status);
        Assert.Equal(HttpStatusCode.BadRequest, (await Post(admin, "/api/v1/inventory/items", new
        {
            itemKind = "unicorn", brandName = "Zz guard", genericName = "P", baseUomCode = "TAB",
        })).Status);
    }

    [Fact]
    public async Task Opening_stock_rejects_unknown_store_and_bad_lines()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var unknownStore = await Post(admin, "/api/v1/inventory/opening-stock", new
        {
            storeId = Guid.NewGuid(),
            lines = new[] { new { itemId = Guid.NewGuid(), batchNo = "B", expiryDate = TestDates.YearsAhead(4, 150), mrpPaise = 100, purchaseRatePaise = 50, qtyBase = 1 } },
        }, Guid.NewGuid());
        Assert.True((int)unknownStore.Status is 400 or 404, $"unknown store gave {(int)unknownStore.Status}");

        var empty = await Post(admin, "/api/v1/inventory/opening-stock", new { storeId = Guid.NewGuid(), lines = Array.Empty<object>() }, Guid.NewGuid());
        Assert.True((int)empty.Status is 400 or 404, $"empty lines gave {(int)empty.Status}");
    }

    [Fact]
    public async Task Another_tenant_never_sees_alpha_inventory()
    {
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        var items = await beta.GetAsync("/api/v1/inventory/items");
        Assert.Equal(HttpStatusCode.OK, items.StatusCode);
        var body = await items.Content.ReadAsStringAsync();
        Assert.DoesNotContain("Crocin", body);
        Assert.DoesNotContain(Alpha.ToString(), body);

        var stock = await beta.GetAsync($"/api/v1/inventory/stock?branchId={AlphaMain}");
        var stockBody = await stock.Content.ReadAsStringAsync();
        Assert.DoesNotContain("Crocin", stockBody);
        Assert.DoesNotContain(Alpha.ToString(), stockBody);
    }

    [Fact]
    public async Task Opening_stock_needs_a_uuid_idempotency_key_and_both_rights()
    {
        var line = new { itemId = Guid.NewGuid(), batchNo = "B", expiryDate = TestDates.YearsAhead(4, 150), mrpPaise = 100, purchaseRatePaise = 50, qtyBase = 1 };
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.BadRequest, (await Post(admin, "/api/v1/inventory/opening-stock", new { storeId = Guid.NewGuid(), lines = new[] { line } })).Status);

        using var bad = new HttpRequestMessage(HttpMethod.Post, "/api/v1/inventory/opening-stock") { Content = JsonContent.Create(new { storeId = Guid.NewGuid(), lines = new[] { line } }) };
        bad.Headers.TryAddWithoutValidation("Idempotency-Key", "not-a-uuid");
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.SendAsync(bad)).StatusCode);

        using var reception = factory.ClientAs(AlphaReception, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.Forbidden, (await Post(reception, "/api/v1/inventory/opening-stock", new { storeId = Guid.NewGuid(), lines = new[] { line } }, Guid.NewGuid())).Status);
    }

    [Fact]
    public async Task Another_tenant_cannot_pick_or_post_against_alpha_stores()
    {
        using var alpha = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var stores = JsonDocument.Parse(await alpha.GetStringAsync("/api/v1/inventory/stores")).RootElement;
        var storeId = stores.GetArrayLength() > 0 ? stores[0].GetProperty("id").GetGuid() : Guid.NewGuid();
        var items = JsonDocument.Parse(await alpha.GetStringAsync("/api/v1/inventory/items")).RootElement.GetProperty("items");
        var itemId = items.GetArrayLength() > 0 ? items[0].GetProperty("id").GetGuid() : Guid.NewGuid();

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        var fefo = await beta.GetAsync($"/api/v1/inventory/fefo?storeId={storeId}&itemId={itemId}&qty=1");
        var fefoBody = await fefo.Content.ReadAsStringAsync();
        Assert.Equal(HttpStatusCode.NotFound, fefo.StatusCode);
        Assert.DoesNotContain(Alpha.ToString(), fefoBody);

        var post = await Post(beta, "/api/v1/inventory/opening-stock", new
        {
            storeId, lines = new[] { new { itemId, batchNo = "ZZ-X", expiryDate = TestDates.YearsAhead(4, 150), mrpPaise = 100, purchaseRatePaise = 50, qtyBase = 1 } },
        }, Guid.NewGuid());
        Assert.True((int)post.Status is 400 or 403 or 404, $"cross-tenant opening gave {(int)post.Status}");
    }

    [Fact]
    public async Task Anonymous_callers_get_401()
    {
        using var anon = factory.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await anon.GetAsync("/api/v1/inventory/stock")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await anon.GetAsync("/api/v1/inventory/items")).StatusCode);
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Post(HttpClient client, string path, object body, Guid? key = null)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, path) { Content = JsonContent.Create(body) };
        if (key is { } k)
        {
            request.Headers.TryAddWithoutValidation("Idempotency-Key", k.ToString());
        }

        var response = await client.SendAsync(request);
        var text = await response.Content.ReadAsStringAsync();
        return (response.StatusCode, string.IsNullOrWhiteSpace(text) ? default : JsonDocument.Parse(text).RootElement.Clone());
    }
}
