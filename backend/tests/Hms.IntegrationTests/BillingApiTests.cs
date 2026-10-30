using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Hms.Modules.Billing.Payments;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>OP billing through the edge: draft, discount approval, collect, cash ceiling, public link.</summary>
[Trait("Category", "Database")]
// #243: shares AlphaAdmin's counter session (one per branch and cashier; tests close it and assert exact cash), so never run in parallel.
[Collection("AlphaAdminCounterSession")]
public sealed class BillingApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly Guid AlphaTenant = Alpha;
    private static readonly Guid Main = AlphaMain;

    [Fact]
    public async Task Consult_bill_is_finalized_collected_and_idempotent()
    {
        using var admin = factory.ClientAs(AlphaAdmin, AlphaTenant, Main);
        var opened = await Post(admin, "/api/v1/accounts", new { patientId = await NewPatientAsync(admin, Main), branchId = Main });
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
        Assert.StartsWith("DEMOB", billNo);

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
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.PostAsJsonAsync("/api/v1/accounts", new { patientId = Guid.NewGuid(), branchId = Main })).StatusCode);

        using var admin = factory.ClientAs(AlphaAdmin, AlphaTenant, Main);
        var opened = await Post(admin, "/api/v1/accounts", new { patientId = await NewPatientAsync(admin, Main), branchId = Main });
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
        var opened = await Post(admin, "/api/v1/accounts", new { patientId = await NewPatientAsync(admin, Main), branchId = Main });
        var billId = opened.Body.GetProperty("id").GetString()!;
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" })).Status);
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/finalize", new { })).Status);

        var unconfigured = await Post(admin, $"/api/v1/bills/{billId}/payment-links", new { channel = "qr" });
        Assert.Equal(HttpStatusCode.OK, unconfigured.Status);
        Assert.Equal(JsonValueKind.Null, unconfigured.Body.GetProperty("upiUri").ValueKind);
        Assert.False(unconfigured.Body.GetProperty("upiConfigured").GetBoolean());

        var vpa = await Post(admin, "/api/v1/payment-accounts", new { branchId = Main, mode = "upi", label = "Front desk", vpa = "alpha.main@okaxis" });
        Assert.Equal(HttpStatusCode.OK, vpa.Status);
        var link = await Post(admin, $"/api/v1/bills/{billId}/payment-links", new { channel = "qr" });
        Assert.Equal(HttpStatusCode.OK, link.Status);
        var order = link.Body.GetProperty("providerOrderId").GetString()!;
        Assert.Contains("upi://pay?pa=alpha.main%40okaxis", link.Body.GetProperty("upiUri").GetString());
        var path = link.Body.GetProperty("path").GetString()!;

        using var anon = factory.CreateClient();
        var receipt = await anon.GetAsync(path);
        Assert.Equal(HttpStatusCode.OK, receipt.StatusCode);
        Assert.Equal(50000, (await Read(receipt)).GetProperty("duePaise").GetInt64());

        Assert.DoesNotContain("sandbox", link.Body.GetProperty("upiUri").GetString(), StringComparison.OrdinalIgnoreCase);
        var eventId = Guid.NewGuid().ToString("N");
        var body = JsonSerializer.Serialize(new { eventId, providerOrderId = order, status = "paid", amountPaise = 50000, tenantId = Guid.NewGuid() });
        using var missing = new HttpRequestMessage(HttpMethod.Post, "/api/v1/billing-public/webhooks/stub")
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
        Assert.Equal(HttpStatusCode.Unauthorized, (await anon.SendAsync(missing)).StatusCode);

        using var shared = Signed("/api/v1/billing-public/webhooks/stub", body, DateTimeOffset.UtcNow);
        shared.Headers.Remove(WebhookSignature.HeaderName);
        shared.Headers.TryAddWithoutValidation("X-Billing-Webhook-Secret", "local-billing-webhook");
        Assert.Equal(HttpStatusCode.Unauthorized, (await anon.SendAsync(shared)).StatusCode);

        var flipped = WebhookSignature.Sign("local-billing-webhook", Encoding.UTF8.GetBytes(body), DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        flipped = flipped[..^1] + (flipped[^1] == 'a' ? "b" : "a");
        using var bad = new HttpRequestMessage(HttpMethod.Post, "/api/v1/billing-public/webhooks/stub")
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
        bad.Headers.TryAddWithoutValidation(WebhookSignature.HeaderName, flipped);
        Assert.Equal(HttpStatusCode.Unauthorized, (await anon.SendAsync(bad)).StatusCode);

        using var stale = Signed("/api/v1/billing-public/webhooks/stub", body, DateTimeOffset.UtcNow.AddMinutes(-10));
        Assert.Equal(HttpStatusCode.Unauthorized, (await anon.SendAsync(stale)).StatusCode);

        var shortBody = JsonSerializer.Serialize(new { eventId, providerOrderId = order, status = "paid", amountPaise = 1 });
        using var partial = Signed("/api/v1/billing-public/webhooks/stub", shortBody, DateTimeOffset.UtcNow);
        Assert.Equal(HttpStatusCode.BadRequest, (await anon.SendAsync(partial)).StatusCode);

        using var hook = Signed("/api/v1/billing-public/webhooks/stub", body, DateTimeOffset.UtcNow);
        var applied = await Read(await anon.SendAsync(hook));
        Assert.False(applied.GetProperty("duplicate").GetBoolean());
        Assert.True(applied.GetProperty("applied").GetBoolean());

        using var replay = Signed("/api/v1/billing-public/webhooks/stub", body, DateTimeOffset.UtcNow);
        Assert.True((await Read(await anon.SendAsync(replay))).GetProperty("duplicate").GetBoolean());
        Assert.Equal(0, (await Get(admin, $"/api/v1/bills/{billId}")).Body.GetProperty("duePaise").GetInt64());

        using var live = Signed("/api/v1/billing-public/webhooks/razorpay", body, DateTimeOffset.UtcNow);
        Assert.Equal(HttpStatusCode.Unauthorized, (await anon.SendAsync(live)).StatusCode);
    }

    [Fact]
    public async Task Consultation_is_collected_then_a_procedure_is_added_on_the_same_bill()
    {
        using var admin = factory.ClientAs(AlphaAdmin, AlphaTenant, Main);
        var session = await Post(admin, "/api/v1/counter-sessions/ensure", new { branchId = Main });
        Assert.Equal(HttpStatusCode.OK, session.Status);
        var sessionId = session.Body.GetProperty("id").GetGuid();

        var opened = await Post(admin, "/api/v1/accounts", new { patientId = await NewPatientAsync(admin, Main), branchId = Main });
        Assert.Equal(HttpStatusCode.OK, opened.Status);
        var billId = opened.Body.GetProperty("id").GetGuid();
        var accountId = opened.Body.GetProperty("accountId").GetGuid();
        var lined = await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" });
        Assert.Equal(50000, lined.Body.GetProperty("totalPaise").GetInt64());
        Assert.Equal("draft", lined.Body.GetProperty("status").GetString());

        var refused = await PayCash(admin, Guid.NewGuid(), accountId, billId, 50000, null);
        Assert.Equal(HttpStatusCode.Conflict, refused.Status);

        var consult = await PayCash(admin, Guid.NewGuid(), accountId, billId, 50000, sessionId);
        Assert.Equal(HttpStatusCode.OK, consult.Status);
        Assert.Equal(sessionId, consult.Body.GetProperty("counterSessionId").GetGuid());
        var afterConsult = await Get(admin, $"/api/v1/bills/{billId}");
        Assert.Equal("draft", afterConsult.Body.GetProperty("status").GetString());
        Assert.Equal(JsonValueKind.Null, afterConsult.Body.GetProperty("billNo").ValueKind);
        Assert.Equal(0, afterConsult.Body.GetProperty("duePaise").GetInt64());

        var item = await Post(admin, "/api/v1/service-items", new { name = $"Wound dressing {Guid.NewGuid():N}", category = "procedure" });
        Assert.Equal(HttpStatusCode.OK, item.Status);
        var serviceItemId = item.Body.GetProperty("id").GetGuid();
        var lists = await Get(admin, "/api/v1/price-lists");
        Guid? standard = null;
        foreach (var list in lists.Body.EnumerateArray())
        {
            if (list.GetProperty("name").GetString() == "Standard" && list.GetProperty("branchId").ValueKind == JsonValueKind.Null)
            {
                standard = list.GetProperty("id").GetGuid();
            }
        }

        Assert.NotNull(standard);
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, "/api/v1/price-lists/items", new
        {
            priceListId = standard,
            serviceItemId,
            unitPricePaise = 15000,
            effectiveFrom = "2017-07-01",
        })).Status);
        var withProcedure = await Post(admin, $"/api/v1/bills/{billId}/lines", new { serviceItemId });
        Assert.Equal(HttpStatusCode.OK, withProcedure.Status);
        Assert.Equal(billId, withProcedure.Body.GetProperty("id").GetGuid());
        Assert.Equal(15000, withProcedure.Body.GetProperty("duePaise").GetInt64());

        var procedure = await PayCash(admin, Guid.NewGuid(), accountId, billId, 15000, sessionId);
        Assert.Equal(HttpStatusCode.OK, procedure.Status);
        var settled = await Get(admin, $"/api/v1/bills/{billId}");
        Assert.Equal(0, settled.Body.GetProperty("duePaise").GetInt64());
        Assert.Equal(JsonValueKind.Null, settled.Body.GetProperty("billNo").ValueKind);

        var closed = await Post(admin, $"/api/v1/bills/{billId}/finalize", new { });
        Assert.Equal(HttpStatusCode.OK, closed.Status);
        Assert.Equal("finalized", closed.Body.GetProperty("status").GetString());
        var billNo = closed.Body.GetProperty("billNo").GetString()!;
        Assert.Equal(16, billNo.Length);
        Assert.StartsWith("DEMOB", billNo);

        var drawer = await Post(admin, $"/api/v1/counter-sessions/{sessionId}/close", new { countedCashPaise = 65000 });
        Assert.Equal(HttpStatusCode.OK, drawer.Status);
        Assert.Equal(65000, drawer.Body.GetProperty("expectedCashPaise").GetInt64());
    }

    [Fact]
    public async Task Close_session_expected_cash_includes_counter_cash_and_cash_refunds()
    {
        using var admin = factory.ClientAs(AlphaAdmin, AlphaTenant, Main);
        var session = await Post(admin, "/api/v1/counter-sessions/ensure", new { branchId = Main });
        var sessionId = session.Body.GetProperty("id").GetGuid();

        var opened = await Post(admin, "/api/v1/accounts", new { patientId = await NewPatientAsync(admin, Main), branchId = Main });
        var billId = opened.Body.GetProperty("id").GetGuid();
        var accountId = opened.Body.GetProperty("accountId").GetGuid();
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" })).Status);

        var paid = await PayCash(admin, Guid.NewGuid(), accountId, billId, 50000, sessionId);
        Assert.Equal(HttpStatusCode.OK, paid.Status);
        var paymentId = paid.Body.GetProperty("id").GetGuid();

        var refund = await Post(admin, $"/api/v1/payments/{paymentId}/refunds", new { amountPaise = 10000, mode = "cash" });
        Assert.Equal(HttpStatusCode.OK, refund.Status);
        Assert.Equal("refund", refund.Body.GetProperty("kind").GetString());
        Assert.Equal(sessionId, refund.Body.GetProperty("counterSessionId").GetGuid());

        var closed = await Post(admin, $"/api/v1/counter-sessions/{sessionId}/close", new { countedCashPaise = 40000 });
        Assert.Equal(HttpStatusCode.OK, closed.Status);
        Assert.Equal(40000, closed.Body.GetProperty("expectedCashPaise").GetInt64());
        Assert.Equal(0, closed.Body.GetProperty("variancePaise").GetInt64());
        Assert.Equal("closed", closed.Body.GetProperty("status").GetString());
    }

    [Fact]
    public async Task Updating_a_payment_is_rejected()
    {
        using var admin = factory.ClientAs(AlphaAdmin, AlphaTenant, Main);
        var opened = await Post(admin, "/api/v1/accounts", new { patientId = await NewPatientAsync(admin, Main), branchId = Main });
        var billId = opened.Body.GetProperty("id").GetGuid();
        var accountId = opened.Body.GetProperty("accountId").GetGuid();
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" })).Status);
        var paid = await Pay(admin, Guid.NewGuid(), accountId, billId, 50000);
        Assert.Equal(HttpStatusCode.OK, paid.Status);
        var paymentId = paid.Body.GetProperty("id").GetGuid();

        await using var owner = new NpgsqlConnection(AdminConnection);
        await owner.OpenAsync();
        await using (var update = new NpgsqlCommand("update billing.payment set amount_paise = amount_paise where id = @id", owner))
        {
            update.Parameters.AddWithValue("id", paymentId);
            var rejected = await Assert.ThrowsAsync<PostgresException>(() => update.ExecuteNonQueryAsync());
            Assert.Equal("55000", rejected.SqlState);
        }

        await using var billing = new NpgsqlConnection(ServiceConnection("billing"));
        await billing.OpenAsync();
        await using (var role = new NpgsqlCommand("set role hms_svc_billing", billing))
        {
            await role.ExecuteNonQueryAsync();
        }

        await using var denied = new NpgsqlCommand("update billing.payment set is_deleted = true where id = @id", billing);
        denied.Parameters.AddWithValue("id", paymentId);
        var privilege = await Assert.ThrowsAsync<PostgresException>(() => denied.ExecuteNonQueryAsync());
        Assert.Equal("42501", privilege.SqlState);
    }

    [Fact]
    public async Task Same_discount_twice_is_idempotent_and_total_discount_is_capped_at_the_subtotal()
    {
        // #154
        using var admin = factory.ClientAs(AlphaAdmin, AlphaTenant, Main);
        var opened = await Post(admin, "/api/v1/accounts", new { patientId = await NewPatientAsync(admin, Main), branchId = Main });
        Assert.Equal(HttpStatusCode.OK, opened.Status);
        var billId = Guid.Parse(opened.Body.GetProperty("id").GetString()!);
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" })).Status);
        var before = (await Get(admin, $"/api/v1/bills/{billId}")).Body.GetProperty("exactPaise").GetInt64();

        var body = new { kind = "flat_paise", value = 100, reasonCode = "Zz-QA courtesy" };
        var first = await Post(admin, $"/api/v1/bills/{billId}/discounts", body);
        Assert.Equal(HttpStatusCode.OK, first.Status);
        var second = await Post(admin, $"/api/v1/bills/{billId}/discounts", body);
        Assert.Equal(HttpStatusCode.OK, second.Status);
        Assert.Equal(first.Body.GetProperty("approvalId").GetString(), second.Body.GetProperty("approvalId").GetString());
        Assert.True(second.Body.GetProperty("duplicate").GetBoolean());
        var after = (await Get(admin, $"/api/v1/bills/{billId}")).Body;
        Assert.True(after.GetProperty("exactPaise").GetInt64() >= before - 100, "the repeat must not discount the bill a second time");

        var over = await Post(admin, $"/api/v1/bills/{billId}/discounts", new { kind = "flat_paise", value = before, reasonCode = "Zz-QA staff" });
        Assert.Equal(HttpStatusCode.BadRequest, over.Status);
        Assert.Contains("total discounts would exceed the bill", over.Body.GetRawText());
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

    private static async Task<(HttpStatusCode Status, JsonElement Body)> PayCash(
        HttpClient client, Guid key, Guid accountId, Guid billId, long amount, Guid? sessionId)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/payments")
        {
            Content = JsonContent.Create(new
            {
                accountId,
                kind = "payment",
                counterSessionId = sessionId,
                tenders = new[] { new { mode = "cash", amountPaise = amount } },
                allocations = new[] { new { billId, amountPaise = amount } },
            }),
        };
        request.Headers.TryAddWithoutValidation("Idempotency-Key", key.ToString());
        var response = await client.SendAsync(request);
        return (response.StatusCode, await Read(response));
    }

    private static HttpRequestMessage Signed(string path, string body, DateTimeOffset stamped)
    {
        var bytes = Encoding.UTF8.GetBytes(body);
        var request = new HttpRequestMessage(HttpMethod.Post, path)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
        request.Headers.TryAddWithoutValidation(
            WebhookSignature.HeaderName,
            WebhookSignature.Sign("local-billing-webhook", bytes, stamped.ToUnixTimeSeconds()));
        return request;
    }

    private static async Task<JsonElement> Read(HttpResponseMessage response)
    {
        var text = await response.Content.ReadAsStringAsync();
        return string.IsNullOrWhiteSpace(text) ? default : JsonDocument.Parse(text).RootElement.Clone();
    }
}
