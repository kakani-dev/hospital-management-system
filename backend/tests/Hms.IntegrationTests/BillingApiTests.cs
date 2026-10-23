using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>OP billing through the edge: draft, discount approval, collect, cash ceiling, public link.</summary>
[Trait("Category", "Database")]
public sealed class BillingApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly Guid AlphaTenant = Alpha;
    private static readonly Guid Main = AlphaMain;

    [Fact]
    public async Task Consult_bill_is_finalized_collected_and_idempotent()
    {
        using var admin = factory.ClientAs(AlphaAdmin, AlphaTenant, Main);
        var opened = await Post(admin, "/api/v1/accounts", new { patientId = AlphaPatientId, branchId = Main });
        Assert.Equal(HttpStatusCode.OK, opened.Status);
        var billId = Guid.Parse(opened.Body.GetProperty("id").GetString()!);
        var accountId = Guid.Parse(opened.Body.GetProperty("accountId").GetString()!);

        var lined = await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" });
        Assert.Equal(HttpStatusCode.OK, lined.Status);
        Assert.Equal(50000, lined.Body.GetProperty("exactPaise").GetInt64());
        Assert.Equal(0, lined.Body.GetProperty("taxPaise").GetInt64());
        Assert.Equal(0, lined.Body.GetProperty("roundOffPaise").GetInt64());

        using var desk = factory.ClientAs(AlphaReception, AlphaTenant, Main);
        var pending = await Post(desk, $"/api/v1/bills/{billId}/discounts", new { kind = "percent_bp", value = 5000, reasonCode = "staff" });
        Assert.Equal(HttpStatusCode.OK, pending.Status);
        Assert.Equal("pending", pending.Body.GetProperty("status").GetString());
        var approvalId = Guid.Parse(pending.Body.GetProperty("approvalId").GetString()!);

        var decided = await Post(admin, $"/api/v1/approvals/{approvalId}/decide", new { status = "approved", note = "ok" });
        Assert.Equal(HttpStatusCode.OK, decided.Status);
        Assert.Equal(25000, decided.Body.GetProperty("totalPaise").GetInt64());

        var finalized = await Post(admin, $"/api/v1/bills/{billId}/finalize", new { });
        Assert.Equal(HttpStatusCode.OK, finalized.Status);
        Assert.Equal("finalized", finalized.Body.GetProperty("status").GetString());
        var billNo = finalized.Body.GetProperty("billNo").GetString()!;
        Assert.Equal(16, billNo.Length);
        Assert.StartsWith("OPB", billNo);

        var changed = await admin.SendAsync(new HttpRequestMessage(HttpMethod.Delete, $"/api/v1/bills/{billId}/lines/{Guid.NewGuid()}"));
        Assert.Equal(HttpStatusCode.Conflict, changed.StatusCode);

        var key = Guid.NewGuid();
        var paid = await Pay(admin, key, accountId, billId, 25000);
        Assert.Equal(HttpStatusCode.OK, paid.Status);
        var again = await Pay(admin, key, accountId, billId, 25000);
        Assert.Equal(paid.Body.GetProperty("id").GetString(), again.Body.GetProperty("id").GetString());
        Assert.Equal(0, (await Get(admin, $"/api/v1/bills/{billId}")).Body.GetProperty("duePaise").GetInt64());

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync($"/api/v1/bills/{billId}")).StatusCode);
    }

    [Fact]
    public async Task Cash_at_two_lakh_is_refused_and_a_stranger_cannot_bill()
    {
        using var anon = factory.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await anon.GetAsync($"/api/v1/bills/{Guid.NewGuid()}")).StatusCode);

        using var lab = factory.ClientAs(AlphaLab, AlphaTenant, Main);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.PostAsJsonAsync("/api/v1/accounts", new { patientId = AlphaPatientId, branchId = Main })).StatusCode);

        using var admin = factory.ClientAs(AlphaAdmin, AlphaTenant, Main);
        var opened = await Post(admin, "/api/v1/accounts", new { patientId = AlphaPatientId, branchId = Main });
        var accountId = opened.Body.GetProperty("accountId").GetString();
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/payments")
        {
            Content = JsonContent.Create(new
            {
                accountId,
                kind = "advance",
                tenders = new[] { new { mode = "cash", amountPaise = 20_000_000 } },
            }),
        };
        request.Headers.TryAddWithoutValidation("Idempotency-Key", Guid.NewGuid().ToString());
        var refused = await admin.SendAsync(request);
        Assert.Equal(HttpStatusCode.BadRequest, refused.StatusCode);
    }

    [Fact]
    public async Task Payment_link_is_public_and_the_webhook_reconciles_once()
    {
        using var admin = factory.ClientAs(AlphaAdmin, AlphaTenant, Main);
        var opened = await Post(admin, "/api/v1/accounts", new { patientId = AlphaPatientId, branchId = Main });
        var billId = opened.Body.GetProperty("id").GetString()!;
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" })).Status);
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/finalize", new { })).Status);

        var link = await Post(admin, $"/api/v1/bills/{billId}/payment-links", new { channel = "qr" });
        Assert.Equal(HttpStatusCode.OK, link.Status);
        var order = link.Body.GetProperty("providerOrderId").GetString()!;
        Assert.Contains("upi://pay", link.Body.GetProperty("upiUri").GetString());
        var path = link.Body.GetProperty("path").GetString()!;

        using var anon = factory.CreateClient();
        var receipt = await anon.GetAsync(path);
        Assert.Equal(HttpStatusCode.OK, receipt.StatusCode);
        Assert.Equal(50000, (await Read(receipt)).GetProperty("duePaise").GetInt64());

        var body = JsonSerializer.Serialize(new { eventId = Guid.NewGuid().ToString("N"), providerOrderId = order, status = "paid", amountPaise = 50000 });
        using var missing = new HttpRequestMessage(HttpMethod.Post, "/api/v1/billing-public/webhooks/stub")
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
        Assert.Equal(HttpStatusCode.Unauthorized, (await anon.SendAsync(missing)).StatusCode);

        using var hook = new HttpRequestMessage(HttpMethod.Post, "/api/v1/billing-public/webhooks/stub")
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
        hook.Headers.TryAddWithoutValidation("X-Billing-Webhook-Secret", "local-billing-webhook");
        var applied = await Read(await anon.SendAsync(hook));
        Assert.False(applied.GetProperty("duplicate").GetBoolean());
        Assert.True(applied.GetProperty("applied").GetBoolean());

        using var replay = new HttpRequestMessage(HttpMethod.Post, "/api/v1/billing-public/webhooks/stub")
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
        replay.Headers.TryAddWithoutValidation("X-Billing-Webhook-Secret", "local-billing-webhook");
        Assert.True((await Read(await anon.SendAsync(replay))).GetProperty("duplicate").GetBoolean());
        Assert.Equal(0, (await Get(admin, $"/api/v1/bills/{billId}")).Body.GetProperty("duePaise").GetInt64());
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Post(HttpClient client, string path, object body)
    {
        var response = await client.PostAsJsonAsync(path, body);
        return (response.StatusCode, await Read(response));
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Get(HttpClient client, string path)
    {
        var response = await client.GetAsync(path);
        return (response.StatusCode, await Read(response));
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Pay(HttpClient client, Guid key, Guid accountId, Guid billId, long amount)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/payments")
        {
            Content = JsonContent.Create(new
            {
                accountId,
                kind = "payment",
                tenders = new[] { new { mode = "upi", amountPaise = amount } },
                allocations = new[] { new { billId, amountPaise = amount } },
            }),
        };
        request.Headers.TryAddWithoutValidation("Idempotency-Key", key.ToString());
        var response = await client.SendAsync(request);
        return (response.StatusCode, await Read(response));
    }

    private static async Task<JsonElement> Read(HttpResponseMessage response)
    {
        var text = await response.Content.ReadAsStringAsync();
        return string.IsNullOrWhiteSpace(text) ? default : JsonDocument.Parse(text).RootElement.Clone();
    }
}
