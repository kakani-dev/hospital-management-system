using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>#72 / REG-032, REG-038: finalized-bill and counter-session guards through the API.</summary>
[Trait("Category", "Database")]
// #243: shares AlphaAdmin's counter session (one per branch and cashier; tests close it and assert exact cash), so never run in parallel.
[Collection("AlphaAdminCounterSession")]
public sealed class BillSessionGuardsApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Finalized_bill_rejects_new_lines_and_discounts()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var (billId, _) = await OpenBill(admin);
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/finalize", new { })).Status);

        var line = await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" });
        Assert.Equal(HttpStatusCode.Conflict, line.Status);
        var discount = await Post(admin, $"/api/v1/bills/{billId}/discounts", new { kind = "percent_bp", value = 1000, reasonCode = "staff" });
        Assert.Equal(HttpStatusCode.Conflict, discount.Status);
    }

    [Fact]
    public async Task Cash_needs_an_open_session_and_a_closed_session_is_frozen()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaEast);
        var (billId, accountId) = await OpenBill(admin, AlphaEast);

        var noSession = await PayCash(admin, accountId, billId, 10000, null);
        Assert.Equal(HttpStatusCode.Conflict, noSession.Status);

        var session = await Post(admin, "/api/v1/counter-sessions/ensure", new { branchId = AlphaEast });
        Assert.Equal(HttpStatusCode.OK, session.Status);
        var sessionId = session.Body.GetProperty("id").GetGuid();
        var again = await Post(admin, "/api/v1/counter-sessions/ensure", new { branchId = AlphaEast });
        Assert.Equal(sessionId, again.Body.GetProperty("id").GetGuid());

        var closed = await Post(admin, $"/api/v1/counter-sessions/{sessionId}/close", new { countedCashPaise = 0 });
        Assert.Equal(HttpStatusCode.OK, closed.Status);
        var closeTwice = await Post(admin, $"/api/v1/counter-sessions/{sessionId}/close", new { countedCashPaise = 0 });
        Assert.Equal(HttpStatusCode.Conflict, closeTwice.Status);

        var onClosed = await PayCash(admin, accountId, billId, 10000, sessionId);
        Assert.Equal(HttpStatusCode.Conflict, onClosed.Status);
    }

    [Fact]
    public async Task Session_of_another_cashier_or_tenant_cannot_be_used()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var session = await Post(admin, "/api/v1/counter-sessions/ensure", new { branchId = AlphaMain });
        var sessionId = session.Body.GetProperty("id").GetGuid();

        using var desk = factory.ClientAs(AlphaReception, Alpha, AlphaMain);
        var (billId, accountId) = await OpenBill(desk);
        var foreignCashier = await PayCash(desk, accountId, billId, 10000, sessionId);
        Assert.Equal(HttpStatusCode.Forbidden, foreignCashier.Status);

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        var foreignTenant = await Post(beta, $"/api/v1/counter-sessions/{sessionId}/close", new { countedCashPaise = 0 });
        Assert.Equal(HttpStatusCode.NotFound, foreignTenant.Status);
    }

    [Fact]
    public async Task Counter_left_open_from_an_earlier_day_is_marked_stale_and_never_reused()
    {
        // #283: relative dates only; the drawer is backdated by one day from whatever "today" is.
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaEast);
        var first = await Post(admin, "/api/v1/counter-sessions/ensure", new { branchId = AlphaEast });
        Assert.Equal(HttpStatusCode.OK, first.Status);
        var staleId = first.Body.GetProperty("id").GetGuid();
        var today = DateOnly.Parse(first.Body.GetProperty("businessDate").GetString()!);

        await using var owner = new Npgsql.NpgsqlConnection(AdminConnection);
        await owner.OpenAsync();
        await using (var backdate = new Npgsql.NpgsqlCommand(
            "update billing.counter_session set business_date = business_date - 1 where id = @id", owner))
        {
            backdate.Parameters.AddWithValue("id", staleId);
            Assert.Equal(1, await backdate.ExecuteNonQueryAsync());
        }

        var (billId, accountId) = await OpenBill(admin, AlphaEast);
        var onStale = await PayCash(admin, accountId, billId, 10000, staleId);
        Assert.Equal(HttpStatusCode.Conflict, onStale.Status);

        var fresh = await Post(admin, "/api/v1/counter-sessions/ensure", new { branchId = AlphaEast });
        Assert.Equal(HttpStatusCode.OK, fresh.Status);
        var freshId = fresh.Body.GetProperty("id").GetGuid();
        Assert.NotEqual(staleId, freshId);
        Assert.Equal(today, DateOnly.Parse(fresh.Body.GetProperty("businessDate").GetString()!));

        await using (var status = new Npgsql.NpgsqlCommand("select status from billing.counter_session where id = @id", owner))
        {
            status.Parameters.AddWithValue("id", staleId);
            Assert.Equal("stale", (string?)await status.ExecuteScalarAsync());
        }

        Assert.Equal(HttpStatusCode.OK, (await PayCash(admin, accountId, billId, 10000, freshId)).Status);

        // The stale drawer is still counted and closed for its own day.
        var closeStale = await Post(admin, $"/api/v1/counter-sessions/{staleId}/close", new { countedCashPaise = 0 });
        Assert.Equal(HttpStatusCode.OK, closeStale.Status);
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/counter-sessions/{freshId}/close", new { countedCashPaise = 10000 })).Status);
    }

    private static async Task<(Guid BillId, Guid AccountId)> OpenBill(HttpClient client, Guid? branch = null)
    {
        var opened = await Post(client, "/api/v1/accounts", new { patientId = await NewPatientAsync(client, branch ?? AlphaMain), branchId = branch ?? AlphaMain });
        Assert.Equal(HttpStatusCode.OK, opened.Status);
        var billId = opened.Body.GetProperty("id").GetGuid();
        Assert.Equal(HttpStatusCode.OK, (await Post(client, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" })).Status);
        return (billId, opened.Body.GetProperty("accountId").GetGuid());
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> PayCash(HttpClient client, Guid accountId, Guid billId, long amount, Guid? sessionId)
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
