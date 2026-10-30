using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>#73 / REG-035: collect an advance, apply it to a later bill, refund what is unused.</summary>
[Trait("Category", "Database")]
public sealed class AdvanceJourneyApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Advance_is_applied_to_a_later_bill_and_the_unused_part_refunded()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);

        var patientId = await NewPatientAsync(admin, AlphaMain);
        var first = await Post(admin, "/api/v1/accounts", new { patientId, branchId = AlphaMain });
        Assert.Equal(HttpStatusCode.OK, first.Status);
        var advance = await Pay(admin, new
        {
            accountId = first.Body.GetProperty("accountId").GetGuid(),
            kind = "advance",
            tenders = new[] { new { mode = "upi", amountPaise = 30000 } },
        });
        Assert.Equal(HttpStatusCode.OK, advance.Status);
        Assert.Equal("advance", advance.Body.GetProperty("kind").GetString());
        var advanceId = advance.Body.GetProperty("id").GetGuid();

        var later = await Post(admin, "/api/v1/accounts", new { patientId, branchId = AlphaMain });
        var billId = later.Body.GetProperty("id").GetGuid();
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" })).Status);

        var tooMuch = await Post(admin, $"/api/v1/bills/{billId}/advances", new { amountPaise = 100_000_000 });
        Assert.NotEqual(HttpStatusCode.OK, tooMuch.Status);
        Assert.True((int)tooMuch.Status is >= 400 and < 500);

        var applied = await Post(admin, $"/api/v1/bills/{billId}/advances", new { amountPaise = 20000 });
        Assert.Equal(HttpStatusCode.OK, applied.Status);
        Assert.Equal(30000, applied.Body.GetProperty("duePaise").GetInt64());
        Assert.Equal(20000, applied.Body.GetProperty("allocatedPaise").GetInt64());

        var unused = await Post(admin, $"/api/v1/payments/{advanceId}/refunds", new { amountPaise = 10000, mode = "upi" });
        Assert.Equal(HttpStatusCode.OK, unused.Status);
        Assert.Equal("refund", unused.Body.GetProperty("kind").GetString());
        var bill = await admin.GetFromJsonAsync<JsonElement>($"/api/v1/bills/{billId}");
        Assert.Equal(30000, bill.GetProperty("duePaise").GetInt64());

        var beyond = await Post(admin, $"/api/v1/payments/{advanceId}/refunds", new { amountPaise = 20001, mode = "upi" });
        Assert.Equal(HttpStatusCode.BadRequest, beyond.Status);

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        var foreign = await Post(beta, $"/api/v1/bills/{billId}/advances", new { amountPaise = 100 });
        Assert.Equal(HttpStatusCode.NotFound, foreign.Status);
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Pay(HttpClient client, object body)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/payments") { Content = JsonContent.Create(body) };
        request.Headers.TryAddWithoutValidation("Idempotency-Key", Guid.NewGuid().ToString());
        var response = await client.SendAsync(request);
        return (response.StatusCode, await Read(response));
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
