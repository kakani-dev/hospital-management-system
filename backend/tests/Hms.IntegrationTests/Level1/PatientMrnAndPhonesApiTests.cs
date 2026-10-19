using System.Net;
using System.Net.Http.Json;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Level1;

/// <summary>
/// Level 1 through the real edge + patients service + Postgres: server-generated MRNs and normalized
/// phone / WhatsApp numbers (patient.patient_phones).
/// </summary>
[Trait("Category", "Database")]
public sealed class PatientMrnAndPhonesApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private sealed record Phone(string Number, bool IsPrimary, bool IsWhatsapp);

    private sealed record Detail(Guid Id, string Mrn, string LastName, string? Phone, List<Phone> Phones, bool WhatsappSameAsPhone);

    private sealed record Summary(Guid Id, string Mrn, string LastName);

    private sealed record Page(List<Summary> Items);

    private sealed record Candidate(Guid Id, List<string> MatchReasons);

    private sealed record Dupes(List<Candidate> Candidates);

    private static string Unique(string prefix) => $"{prefix}-{Guid.NewGuid():N}"[..20];

    private static string NewMobile() => "9" + Random.Shared.NextInt64(100_000_000, 999_999_999).ToString(System.Globalization.CultureInfo.InvariantCulture);

    private static async Task<Detail> ReadAsync(HttpResponseMessage response, HttpStatusCode expected)
    {
        Assert.Equal(expected, response.StatusCode);
        return (await response.Content.ReadFromJsonAsync<Detail>())!;
    }

    [Fact]
    public async Task Same_number_is_stored_once_with_both_flags_and_the_db_agrees()
    {
        var mobile = NewMobile();
        using var client = factory.ClientAs(AlphaReception, Alpha);
        var created = await ReadAsync(await client.PostAsJsonAsync("/api/v1/patients", new
        {
            firstName = "Wa", lastName = Unique("Same"), registeredBranchId = AlphaMain, phone = "0" + mobile,
            whatsapp = new { sameAsPhone = true }, tenantId = Beta, // a client tenant id is ignored
        }), HttpStatusCode.Created);

        Assert.Matches("^DEMO-ALPHA-[0-9]{6,}$", created.Mrn);
        Assert.True(created.WhatsappSameAsPhone);
        Assert.Equal("+91" + mobile, Assert.Single(created.Phones).Number);

        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(
            "select count(*)::int, bool_and(is_primary and is_whatsapp), min(tenant_id::text) from patient.patient_phones where patient_id = @p and not is_deleted", conn);
        cmd.Parameters.AddWithValue("p", created.Id);
        await using var r = await cmd.ExecuteReaderAsync();
        Assert.True(await r.ReadAsync());
        Assert.Equal(1, r.GetInt32(0));
        Assert.True(r.GetBoolean(1));
        Assert.Equal(Alpha.ToString(), r.GetString(2));
    }

    [Fact]
    public async Task Separate_whatsapp_number_is_searchable_and_found_by_the_duplicate_check()
    {
        var mobile = NewMobile();
        var whatsapp = NewMobile();
        var last = Unique("Diff");
        using var client = factory.ClientAs(AlphaReception, Alpha);
        var created = await ReadAsync(await client.PostAsJsonAsync("/api/v1/patients", new
        {
            firstName = "Wa", lastName = last, registeredBranchId = AlphaMain, phone = mobile,
            whatsapp = new { sameAsPhone = false, number = "+91 " + whatsapp },
        }), HttpStatusCode.Created);
        Assert.False(created.WhatsappSameAsPhone);
        Assert.Equal(2, created.Phones.Count);

        var page = await (await client.PostAsJsonAsync("/api/v1/patients/search", new { phone = whatsapp })).Content.ReadFromJsonAsync<Page>();
        Assert.Contains(page!.Items, p => p.Id == created.Id);
        var byMrn = await (await client.PostAsJsonAsync("/api/v1/patients/search", new { search = created.Mrn })).Content.ReadFromJsonAsync<Page>();
        Assert.Equal(created.Id, Assert.Single(byMrn!.Items).Id);

        var dupes = await (await client.PostAsJsonAsync("/api/v1/patients/duplicates", new { phone = "0" + whatsapp })).Content.ReadFromJsonAsync<Dupes>();
        Assert.Contains(dupes!.Candidates, c => c.Id == created.Id && c.MatchReasons.Contains("phone"));

        // collapse to "same", then drop WhatsApp
        var same = await ReadAsync(await client.PatchAsJsonAsync($"/api/v1/patients/{created.Id}", new { whatsapp = new { sameAsPhone = true } }), HttpStatusCode.OK);
        Assert.True(same.WhatsappSameAsPhone);
        Assert.Single(same.Phones);
        var none = await ReadAsync(await client.PatchAsJsonAsync($"/api/v1/patients/{created.Id}", new { whatsapp = (object?)null }), HttpStatusCode.OK);
        Assert.False(none.WhatsappSameAsPhone);
        Assert.False(Assert.Single(none.Phones).IsWhatsapp);
    }

    [Fact]
    public async Task Invalid_numbers_are_400_and_other_tenants_cannot_see_phones()
    {
        using var client = factory.ClientAs(AlphaReception, Alpha);
        var bad = await client.PostAsJsonAsync("/api/v1/patients", new
        {
            firstName = "Bad", lastName = "Phone", registeredBranchId = AlphaMain, phone = "123",
        });
        Assert.Equal(HttpStatusCode.BadRequest, bad.StatusCode);
        Assert.Contains("phone", await bad.Content.ReadAsStringAsync(), StringComparison.Ordinal);

        var created = await ReadAsync(await client.PostAsJsonAsync("/api/v1/patients", new
        {
            firstName = "Iso", lastName = Unique("Iso"), registeredBranchId = AlphaMain, phone = NewMobile(),
            whatsapp = new { sameAsPhone = true },
        }), HttpStatusCode.Created);
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync($"/api/v1/patients/{created.Id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound,
            (await beta.PatchAsJsonAsync($"/api/v1/patients/{created.Id}", new { whatsapp = new { sameAsPhone = false, number = NewMobile() } })).StatusCode);
    }
}
