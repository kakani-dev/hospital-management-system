using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Hms.IntegrationTests.Sprint2;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>GSTIN, tax split, bill list, maker-checker, and a paid cancel refund.</summary>
[Trait("Category", "Database")]
public sealed class BillingBenchmarkApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Branch_gstin_is_snapshotted_and_the_tax_split_follows_place_of_supply()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var saved = await Put(admin, $"/api/v1/price-lists/branches/{AlphaMain}/profile", new { gstin = "36AABCU9603R1ZM", legalName = "Alpha Hospital" });
        Assert.Equal(HttpStatusCode.OK, saved.Status);
        Assert.Equal("36AABCU9603R1ZM", saved.Body.GetProperty("gstin").GetString());

        var bad = await Put(admin, $"/api/v1/price-lists/branches/{AlphaMain}/profile", new { gstin = "NOPE" });
        Assert.Equal(HttpStatusCode.BadRequest, bad.Status);

        var opened = await Post(admin, "/api/v1/accounts", new { patientId = AlphaPatientId, branchId = AlphaMain });
        var billId = opened.Body.GetProperty("id").GetString()!;
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" })).Status);
        var placed = await Put(admin, $"/api/v1/bills/{billId}/place-of-supply", new { stateCode = "27" });
        Assert.Equal(HttpStatusCode.OK, placed.Status);
        Assert.Equal("36AABCU9603R1ZM", placed.Body.GetProperty("supplier").GetProperty("gstin").GetString());
        Assert.Equal(0, placed.Body.GetProperty("igstPaise").GetInt64());
        Assert.Equal(0, placed.Body.GetProperty("cgstPaise").GetInt64());
        Assert.Equal("9993", placed.Body.GetProperty("lines")[0].GetProperty("sacHsnCode").GetString());

        var finalized = await Post(admin, $"/api/v1/bills/{billId}/finalize", new { });
        Assert.Equal("36AABCU9603R1ZM", finalized.Body.GetProperty("supplier").GetProperty("gstin").GetString());
        Assert.Equal(HttpStatusCode.OK, (await Put(admin, $"/api/v1/price-lists/branches/{AlphaMain}/profile", new { gstin = "29AABCU9603R1ZM" })).Status);
        var again = await Get(admin, $"/api/v1/bills/{billId}");
        Assert.Equal("36AABCU9603R1ZM", again.Body.GetProperty("supplier").GetProperty("gstin").GetString());

        var listed = await Get(admin, $"/api/v1/bills?status=finalized&branchId={AlphaMain}");
        Assert.Equal(HttpStatusCode.OK, listed.Status);
        Assert.Contains(listed.Body.EnumerateArray(), row => row.GetProperty("id").GetString() == billId);

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync($"/api/v1/bills/{billId}")).StatusCode);
    }

    [Fact]
    public async Task Discount_above_the_threshold_cannot_be_self_approved()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var settings = await Get(admin, "/api/v1/approvals/settings");
        Assert.Equal(HttpStatusCode.OK, settings.Status);
        Assert.Equal(20000, settings.Body.GetProperty("makerCheckerThresholdPaise").GetInt64());

        var opened = await Post(admin, "/api/v1/accounts", new { patientId = AlphaPatientId, branchId = AlphaMain });
        var billId = opened.Body.GetProperty("id").GetString()!;
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" })).Status);

        using var desk = factory.ClientAs(AlphaReception, Alpha, AlphaMain);
        var small = await Post(desk, $"/api/v1/bills/{billId}/discounts", new { kind = "flat_paise", value = 500, reasonCode = "courtesy" });
        Assert.Equal(HttpStatusCode.OK, small.Status);
        Assert.Equal("approved", small.Body.GetProperty("approvalStatus").GetString());
        Assert.Equal(49500, small.Body.GetProperty("totalPaise").GetInt64());

        var large = await Post(admin, $"/api/v1/bills/{billId}/discounts", new { kind = "flat_paise", value = 25000, reasonCode = "staff" });
        Assert.Equal("pending", large.Body.GetProperty("status").GetString());
        var approvalId = large.Body.GetProperty("approvalId").GetString();
        var denied = await Post(admin, $"/api/v1/approvals/{approvalId}/decide", new { status = "approved" });
        Assert.Equal(HttpStatusCode.Forbidden, denied.Status);
    }

    [Fact]
    public async Task Paid_cancel_after_check_in_waits_for_a_refund_and_a_credit_note()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        using var desk = factory.ClientAs(AlphaReception, Alpha, AlphaMain);
        var practitioner = await S2.CreatePractitionerAsync(admin);
        var start = S2.TodayAt(8, Random.Shared.Next(0, 50));
        var booked = await S2.BookAsync(admin, AlphaMain, practitioner.Id, AlphaPatientId, start);
        Assert.Equal(HttpStatusCode.Created, booked.StatusCode);
        var appointmentId = (await booked.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();

        var checkIn = await desk.PostAsync($"/api/v1/appointments/{appointmentId}/check-in", null);
        Assert.Equal(HttpStatusCode.Created, checkIn.StatusCode);

        var draft = await Post(desk, "/api/v1/accounts/from-appointment", new { appointmentId });
        Assert.Equal(HttpStatusCode.OK, draft.Status);
        Assert.Equal("CONSULT", draft.Body.GetProperty("lines")[0].GetProperty("code").GetString());
        var billId = draft.Body.GetProperty("id").GetGuid();
        var accountId = draft.Body.GetProperty("accountId").GetGuid();
        var due = draft.Body.GetProperty("duePaise").GetInt64();
        var paid = await Pay(admin, Guid.NewGuid(), accountId, billId, due);
        Assert.Equal(HttpStatusCode.OK, paid.Status);

        var cancel = await desk.PostAsJsonAsync($"/api/v1/appointments/{appointmentId}/cancel", new { reason = "patient request" });
        Assert.Equal(HttpStatusCode.OK, cancel.StatusCode);

        var pending = await Get(admin, "/api/v1/approvals?status=pending");
        var refund = pending.Body.EnumerateArray().First(row =>
            row.GetProperty("action").GetString() == "refund"
            && row.GetProperty("payload").TryGetProperty("appointmentId", out var appt)
            && appt.GetString() == appointmentId.ToString());
        var decided = await Post(admin, $"/api/v1/approvals/{refund.GetProperty("id").GetString()}/decide", new { status = "approved" });
        Assert.Equal(HttpStatusCode.OK, decided.Status);
        Assert.False(string.IsNullOrEmpty(decided.Body.GetProperty("creditNoteNo").GetString()));
        Assert.Equal(0, (await Get(admin, $"/api/v1/bills/{billId}")).Body.GetProperty("duePaise").GetInt64());
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Post(HttpClient client, string path, object body)
    {
        var response = await client.PostAsJsonAsync(path, body);
        return (response.StatusCode, await Read(response));
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Put(HttpClient client, string path, object body)
    {
        var response = await client.PutAsJsonAsync(path, body);
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
