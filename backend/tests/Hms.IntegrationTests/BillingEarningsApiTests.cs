using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>Earnings report: role, tenant, ignored client tenant id, export, and the short cache.</summary>
[Trait("Category", "Database")]
public sealed class BillingEarningsApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Todays_invoice_is_in_the_report_and_a_second_read_is_cached()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        var opened = await Post(admin, "/api/v1/accounts", new { patientId = AlphaPatientId, branchId = AlphaMain });
        Assert.Equal(HttpStatusCode.OK, opened.Status);
        var billId = opened.Body.GetProperty("id").GetString()!;
        Assert.Equal(HttpStatusCode.OK, (await Post(admin, $"/api/v1/bills/{billId}/lines", new { code = "CONSULT" })).Status);
        var finalized = await Post(admin, $"/api/v1/bills/{billId}/finalize", new { });
        Assert.Equal(HttpStatusCode.OK, finalized.Status);
        var billNo = finalized.Body.GetProperty("billNo").GetString();
        var total = finalized.Body.GetProperty("totalPaise").GetInt64();
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, TimeZoneInfo.FindSystemTimeZoneById("Asia/Kolkata")).DateTime);
        var path = $"/api/v1/billing-reports/earnings?from={today:yyyy-MM-dd}&to={today:yyyy-MM-dd}";

        var first = await admin.GetAsync(path);
        Assert.Equal(HttpStatusCode.OK, first.StatusCode);
        Assert.Equal("miss", Header(first, "X-Earnings-Cache"));
        var body = await Read(first);
        Assert.Contains(body.GetProperty("sales").EnumerateArray(), row =>
            row.GetProperty("invoiceNumber").GetString() == billNo
            && row.GetProperty("totalPaise").GetInt64() == total);

        var second = await admin.GetAsync(path);
        Assert.Equal(HttpStatusCode.OK, second.StatusCode);
        Assert.Equal("hit", Header(second, "X-Earnings-Cache"));

        var forged = await admin.GetAsync(path + $"&tenantId={Beta}");
        Assert.Equal(HttpStatusCode.OK, forged.StatusCode);
        Assert.Contains((await Read(forged)).GetProperty("sales").EnumerateArray(), row => row.GetProperty("invoiceNumber").GetString() == billNo);

        using var desk = factory.ClientAs(AlphaReception, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.Forbidden, (await desk.GetAsync(path)).StatusCode);

        using var beta = factory.ClientAs(BetaAdmin, Beta, BetaMain);
        var foreign = await beta.GetAsync(path);
        Assert.Equal(HttpStatusCode.OK, foreign.StatusCode);
        Assert.DoesNotContain((await Read(foreign)).GetProperty("sales").EnumerateArray(), row => row.GetProperty("invoiceNumber").GetString() == billNo);

        var csv = await admin.GetAsync($"/api/v1/billing-reports/earnings/export?from={today:yyyy-MM-dd}&to={today:yyyy-MM-dd}&format=csv&section=sales");
        Assert.Equal(HttpStatusCode.OK, csv.StatusCode);
        Assert.Contains("text/csv", csv.Content.Headers.ContentType?.ToString());
        Assert.Contains("Invoice number", await csv.Content.ReadAsStringAsync());

        var sheet = await admin.GetAsync($"/api/v1/billing-reports/earnings/export?from={today:yyyy-MM-dd}&to={today:yyyy-MM-dd}&format=xlsx&section=sales");
        Assert.Equal(HttpStatusCode.OK, sheet.StatusCode);
        var bytes = await sheet.Content.ReadAsByteArrayAsync();
        Assert.Equal((byte)'P', bytes[0]);
        Assert.Equal((byte)'K', bytes[1]);
    }

    private static string? Header(HttpResponseMessage response, string name) =>
        response.Headers.TryGetValues(name, out var values) ? values.Single() : null;

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
