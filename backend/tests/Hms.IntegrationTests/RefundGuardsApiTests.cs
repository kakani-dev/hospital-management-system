using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>#70 / REG-034: refund guards beyond the happy-path cash refund.</summary>
[Trait("Category", "Database")]
// #243: shares AlphaAdmin's counter session (one per branch and cashier; tests close it and assert exact cash), so never run in parallel.
[Collection("AlphaAdminCounterSession")]
public sealed class RefundGuardsApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Refund_cannot_exceed_what_is_still_refundable()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var paymentId = await PaidUpi(admin, 50000);

        var tooMuch = await Post(admin, $"/api/v1/payments/{paymentId}/refunds", new { amountPaise = 50001, mode = "upi" });
        Assert.Equal(HttpStatusCode.BadRequest, tooMuch.Status);

        var part = await Post(admin, $"/api/v1/payments/{paymentId}/refunds", new { amountPaise = 30000, mode = "upi" });
        Assert.Equal(HttpStatusCode.OK, part.Status);

        var rest = await Post(admin, $"/api/v1/payments/{paymentId}/refunds", new { amountPaise = 20001, mode = "upi" });
        Assert.Equal(HttpStatusCode.BadRequest, rest.Status);
        var exact = await Post(admin, $"/api/v1/payments/{paymentId}/refunds", new { amountPaise = 20000, mode = "upi" });
        Assert.Equal(HttpStatusCode.OK, exact.Status);
    }

    [Fact]
    public async Task Refund_of_a_refund_is_rejected()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var paymentId = await PaidUpi(admin, 50000);
        var refund = await Post(admin, $"/api/v1/payments/{paymentId}/refunds", new { amountPaise = 10000, mode = "upi" });
        Assert.Equal(HttpStatusCode.OK, refund.Status);
        var refundId = refund.Body.GetProperty("id").GetGuid();

        var again = await Post(admin, $"/api/v1/payments/{refundId}/refunds", new { amountPaise = 1000, mode = "upi" });
        Assert.Equal(HttpStatusCode.BadRequest, again.Status);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-100)]
    public async Task Refund_amount_must_be_positive(long amount)
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var paymentId = await PaidUpi(admin, 50000);
        var bad = await Post(admin, $"/api/v1/payments/{paymentId}/refunds", new { amountPaise = amount, mode = "upi" });
        Assert.Equal(HttpStatusCode.BadRequest, bad.Status);
    }

    [Fact]
    public async Task Cash_refund_of_a_digital_payment_needs_a_manager()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var paymentId = await PaidUpi(admin, 50000);
        using var desk = factory.ClientAs(AlphaReception, Alpha, AlphaMain);
        await Post(desk, "/api/v1/counter-sessions/ensure", new { branchId = AlphaMain });

        var denied = await Post(desk, $"/api/v1/payments/{paymentId}/refunds", new { amountPaise = 10000, mode = "cash" });
        Assert.Equal(HttpStatusCode.Forbidden, denied.Status);
    }

    [Fact]
    public async Task Another_tenant_cannot_refund_the_payment()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var paymentId = await PaidUpi(admin, 50000);
        using var beta = factory.ClientAs(BetaAdmin, Beta);

        var foreign = await Post(beta, $"/api/v1/payments/{paymentId}/refunds", new { amountPaise = 10000, mode = "upi" });
        Assert.Equal(HttpStatusCode.NotFound, foreign.Status);

        var unknown = await Post(admin, $"/api/v1/payments/{Guid.NewGuid()}/refunds", new { amountPaise = 10000, mode = "upi" });
        Assert.Equal(HttpStatusCode.NotFound, unknown.Status);
    }

    private static async Task<Guid> PaidUpi(HttpClient admin, long amount)
    {
        var opened = await Post(admin, "/api/v1/accounts", new { patientId = await NewPatientAsync(admin, AlphaMain), branchId = AlphaMain });
        Assert.Equal(HttpStatusCode.OK, opened.Status);
        var billId = opened.Body.GetProperty("id").GetGuid();
        var accountId = opened.Body.GetProperty("accountId").GetGuid();
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" })).Status);
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
        request.Headers.TryAddWithoutValidation("Idempotency-Key", Guid.NewGuid().ToString());
        var paid = await admin.SendAsync(request);
        Assert.Equal(HttpStatusCode.OK, paid.StatusCode);
        return (await Read(paid)).GetProperty("id").GetGuid();
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Post(HttpClient client, string path, object body)
    {
        var response = await client.PostAsJsonAsync(path, body);
        return (response.StatusCode, await Read(response));
    }

    private static async Task<JsonElement> Read(HttpResponseMessage response)
    {
        var text = await response.Content.ReadAsStringAsync();
        return string.IsNullOrWhiteSpace(text) ? default : JsonDocument.Parse(text).RootElement.Clone();
    }
}
