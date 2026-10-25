using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>Inventory foundation through the edge: items, stores, opening stock, and stock on hand.</summary>
[Trait("Category", "Database")]
public sealed class InventoryApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Admin_creates_an_item_a_store_and_opening_stock()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var item = await Post(admin, "/api/v1/inventory/items", new
        {
            itemKind = "drug",
            brandName = "Crocin",
            genericName = "Paracetamol",
            strength = "500 mg",
            dosageForm = "tablet",
            manufacturerName = "Acme",
            scheduleCode = "H",
            hsnCode = "30049099",
            gstRateBp = 1200,
            baseUomCode = "TAB",
            packs = new[] { new { uomCode = "STRIP", unitsPerPack = 10, isPurchase = true, isSale = true } },
        });
        Assert.Equal(HttpStatusCode.OK, item.Status);
        Assert.Equal("ITM-0001", item.Body.GetProperty("code").GetString());
        Assert.False(item.Body.TryGetProperty("reorderLevel", out _));
        var itemId = item.Body.GetProperty("id").GetString();

        var coded = await Post(admin, "/api/v1/inventory/items", new { code = "PARA", itemKind = "drug", brandName = "X" });
        Assert.Equal(HttpStatusCode.BadRequest, coded.Status);

        var store = await Post(admin, "/api/v1/inventory/stores", new
        {
            branchId = AlphaMain,
            name = "Pharmacy",
            storeKind = "op_pharmacy",
            drugLicenceNo = "DL-1",
            licenceValidTo = "2030-01-01",
        });
        Assert.Equal(HttpStatusCode.OK, store.Status);
        Assert.Equal("STR-0001", store.Body.GetProperty("code").GetString());
        var storeId = store.Body.GetProperty("id").GetString();

        var unlicensed = await Post(admin, "/api/v1/inventory/stores", new
        {
            branchId = AlphaMain,
            name = "Other pharmacy",
            storeKind = "op_pharmacy",
        });
        Assert.Equal(HttpStatusCode.BadRequest, unlicensed.Status);

        var key = Guid.NewGuid();
        var opened = await Post(admin, "/api/v1/inventory/opening-stock", new
        {
            storeId,
            lines = new[]
            {
                new
                {
                    itemId,
                    batchNo = "B1",
                    expiryDate = "2030-06-01",
                    mrpPaise = 2500,
                    purchaseRatePaise = 1250,
                    qtyBase = 10,
                },
            },
        }, key);
        Assert.Equal(HttpStatusCode.OK, opened.Status);
        Assert.Equal("OPN-0001", opened.Body.GetProperty("docNo").GetString());
        Assert.Equal(AlphaAdmin.ToString(), opened.Body.GetProperty("approverId").GetString());

        var replay = await Post(admin, "/api/v1/inventory/opening-stock", new
        {
            storeId,
            lines = new[]
            {
                new
                {
                    itemId,
                    batchNo = "B9",
                    expiryDate = "2031-01-01",
                    mrpPaise = 1,
                    purchaseRatePaise = 1,
                    qtyBase = 99,
                },
            },
        }, key);
        Assert.Equal(HttpStatusCode.OK, replay.Status);
        Assert.Equal(opened.Body.GetProperty("id").GetString(), replay.Body.GetProperty("id").GetString());

        var stock = await Get(admin, $"/api/v1/inventory/stock?storeId={storeId}");
        Assert.Equal(HttpStatusCode.OK, stock.Status);
        Assert.Equal(1, stock.Body.GetArrayLength());
        Assert.Equal(10, stock.Body[0].GetProperty("onHandBase").GetInt32());
        Assert.Equal(1250, stock.Body[0].GetProperty("purchaseRatePaise").GetInt32());
        Assert.Equal("ok", stock.Body[0].GetProperty("expiryState").GetString());
        Assert.False(stock.Body[0].GetProperty("lowStock").GetBoolean());
        Assert.Equal(JsonValueKind.Null, stock.Body[0].GetProperty("minQty").ValueKind);

        var lowItem = await Post(admin, "/api/v1/inventory/items", new
        {
            itemKind = "consumable",
            brandName = "Gauze pad",
            manufacturerName = "Acme",
            hsnCode = "300590",
            gstRateBp = 500,
            baseUomCode = "PC",
            storeId,
            reorderLevel = 25,
        });
        Assert.Equal(HttpStatusCode.OK, lowItem.Status);
        var lowItemId = lowItem.Body.GetProperty("id").GetString();
        var lowOpened = await Post(admin, "/api/v1/inventory/opening-stock", new
        {
            storeId,
            lines = new[]
            {
                new { itemId = lowItemId, batchNo = "G1", expiryDate = "2031-01-01", mrpPaise = 800, purchaseRatePaise = 400, qtyBase = 4 },
            },
        }, Guid.NewGuid());
        Assert.Equal(HttpStatusCode.OK, lowOpened.Status);
        var flagged = await Get(admin, $"/api/v1/inventory/stock?storeId={storeId}&itemId={lowItemId}");
        Assert.True(flagged.Body[0].GetProperty("lowStock").GetBoolean());
        Assert.Equal(25, flagged.Body[0].GetProperty("minQty").GetInt32());
        var onlyLow = await Get(admin, $"/api/v1/inventory/stock?storeId={storeId}&lowStock=true");
        Assert.Equal(HttpStatusCode.OK, onlyLow.Status);
        Assert.Equal(lowItemId, Assert.Single(onlyLow.Body.EnumerateArray()).GetProperty("itemId").GetString());

        using var desk = factory.ClientAs(AlphaReception, Alpha, AlphaMain);
        var denied = await Post(desk, "/api/v1/inventory/items", new
        {
            itemKind = "consumable",
            brandName = "Gauze",
            manufacturerName = "Acme",
            hsnCode = "3005",
            gstRateBp = 500,
            baseUomCode = "PC",
        });
        Assert.Equal(HttpStatusCode.Forbidden, denied.Status);
        var hidden = await Get(desk, "/api/v1/inventory/stock");
        Assert.Equal(HttpStatusCode.Forbidden, hidden.Status);
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Post(HttpClient client, string path, object body, Guid? idempotencyKey = null)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, path) { Content = JsonContent.Create(body) };
        if (idempotencyKey is { } key)
        {
            request.Headers.TryAddWithoutValidation("Idempotency-Key", key.ToString());
        }

        var response = await client.SendAsync(request);
        return (response.StatusCode, await Read(response));
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Get(HttpClient client, string path)
    {
        var response = await client.GetAsync(path);
        return (response.StatusCode, await Read(response));
    }

    private static async Task<JsonElement> Read(HttpResponseMessage response)
    {
        var text = await response.Content.ReadAsStringAsync();
        return string.IsNullOrWhiteSpace(text) ? default : JsonDocument.Parse(text).RootElement.Clone();
    }
}
