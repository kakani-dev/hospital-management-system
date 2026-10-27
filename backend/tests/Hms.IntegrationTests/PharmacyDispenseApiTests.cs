using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>#106 PR1: pharmacist queue, prescription detail and FEFO dispensing through the edge (inventory service).</summary>
[Trait("Category", "Database")]
// Shares the Beta doctor practitioner row (registration number is toggled in a test), so never run in parallel.
[Collection("BetaDoctorPractitioner")]
public sealed class PharmacyDispenseApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly Guid BetaDoctorPractitioner = Guid.Parse("c2222222-0000-4000-8000-000000000001");
    private static readonly Guid BetaPatient2 = Guid.Parse("bb000000-0000-4000-8000-000000000002");

    [Fact]
    public async Task Pharmacist_sees_the_queue_and_dispenses_fefo_with_partial_lines()
    {
        using var admin = factory.ClientAs(BetaAdmin, Beta, BetaMain);
        var item = await Send(admin, HttpMethod.Post, "/api/v1/inventory/items", new
        {
            itemKind = "drug", brandName = "Zz-QA Amoxy", genericName = "Zz-QA Amoxicillin", strength = "500 mg", dosageForm = "capsule",
            manufacturerName = "Zz-QA Labs", scheduleCode = "H", hsnCode = "30041010", gstRateBp = 1200, baseUomCode = "CAP",
        });
        Assert.Equal(HttpStatusCode.OK, item.Status);
        var itemId = item.Body.GetProperty("id").GetString()!;
        var store = await Send(admin, HttpMethod.Post, "/api/v1/inventory/stores", new
        {
            branchId = BetaMain, name = "Zz-QA Beta OP Pharmacy", storeKind = "op_pharmacy", drugLicenceNo = "ZZ-DL-B", licenceValidTo = "2099-01-01",
        });
        Assert.Equal(HttpStatusCode.OK, store.Status);
        var storeId = store.Body.GetProperty("id").GetString()!;
        var opened = await Send(admin, HttpMethod.Post, "/api/v1/inventory/opening-stock", new
        {
            storeId,
            lines = new object[]
            {
                new { itemId, batchNo = "ZZ-LATE", expiryDate = "2031-12-31", mrpPaise = 900, purchaseRatePaise = 500, qtyBase = 20 },
                new { itemId, batchNo = "ZZ-SOON", expiryDate = "2030-01-31", mrpPaise = 900, purchaseRatePaise = 450, qtyBase = 3 },
                new { itemId, batchNo = "ZZ-OLD", expiryDate = "2020-01-31", mrpPaise = 900, purchaseRatePaise = 400, qtyBase = 50 },
            },
        }, Guid.NewGuid());
        Assert.Equal(HttpStatusCode.OK, opened.Status);

        var rxId = await FinalizedPrescriptionAsync(itemId);
        var pharmacist = await CreateUserAsync("zz-qa-pharmacist", (Beta, BetaMain, "pharmacist"));
        using var ph = factory.ClientAs(pharmacist, Beta, BetaMain);

        var queue = await Send(ph, HttpMethod.Get, $"/api/v1/inventory/pharmacy/queue?branchId={BetaMain}", null);
        Assert.Equal(HttpStatusCode.OK, queue.Status);
        var row = queue.Body.EnumerateArray().Single(r => r.GetProperty("id").GetString() == rxId);
        Assert.Equal("pending", row.GetProperty("status").GetString());
        Assert.False(string.IsNullOrEmpty(row.GetProperty("patientMrn").GetString()));
        Assert.False(string.IsNullOrEmpty(row.GetProperty("doctorName").GetString()));
        var finalized = queue.Body.EnumerateArray().Select(r => r.GetProperty("finalizedOn").GetDateTimeOffset()).ToList();
        Assert.Equal(finalized.Order().ToList(), finalized);

        var detail = await Send(ph, HttpMethod.Get, $"/api/v1/inventory/pharmacy/prescriptions/{rxId}?storeId={storeId}", null);
        Assert.Equal(HttpStatusCode.OK, detail.Status);
        Assert.Equal(23, detail.Body.GetProperty("lines")[0].GetProperty("availableBase").GetInt32());

        Assert.Equal(HttpStatusCode.BadRequest,
            (await Send(ph, HttpMethod.Post, "/api/v1/inventory/pharmacy/dispenses", new { consultationId = rxId, storeId, lines = new[] { new { lineNo = 1, qtyBase = 1 } } })).Status);

        var tooMuch = await Send(ph, HttpMethod.Post, "/api/v1/inventory/pharmacy/dispenses",
            new { consultationId = rxId, storeId, lines = new[] { new { lineNo = 1, qtyBase = 24, complete = true } } }, Guid.NewGuid());
        Assert.Equal(HttpStatusCode.Conflict, tooMuch.Status);

        var key = Guid.NewGuid();
        var part = await Send(ph, HttpMethod.Post, "/api/v1/inventory/pharmacy/dispenses",
            new { consultationId = rxId, storeId, lines = new[] { new { lineNo = 1, qtyBase = 5, complete = false } } }, key);
        Assert.Equal(HttpStatusCode.OK, part.Status);
        Assert.Equal("partial", part.Body.GetProperty("status").GetString());
        var batches = part.Body.GetProperty("dispenses")[0].GetProperty("lines").EnumerateArray()
            .Select(l => (l.GetProperty("batchNo").GetString(), l.GetProperty("qtyBase").GetInt32())).ToList();
        Assert.Equal([("ZZ-SOON", 3), ("ZZ-LATE", 2)], batches);

        var replay = await Send(ph, HttpMethod.Post, "/api/v1/inventory/pharmacy/dispenses",
            new { consultationId = rxId, storeId, lines = new[] { new { lineNo = 1, qtyBase = 5, complete = false } } }, key);
        Assert.Equal(HttpStatusCode.OK, replay.Status);
        Assert.Equal(5, replay.Body.GetProperty("lines")[0].GetProperty("dispensedBase").GetInt32());

        var rest = await Send(ph, HttpMethod.Post, "/api/v1/inventory/pharmacy/dispenses",
            new { consultationId = rxId, storeId, lines = new[] { new { lineNo = 1, qtyBase = 10, complete = true } } }, Guid.NewGuid());
        Assert.Equal("dispensed", rest.Body.GetProperty("status").GetString());
        Assert.Equal(8, rest.Body.GetProperty("lines")[0].GetProperty("availableBase").GetInt32());

        var twice = await Send(ph, HttpMethod.Post, "/api/v1/inventory/pharmacy/dispenses",
            new { consultationId = rxId, storeId, lines = new[] { new { lineNo = 1, qtyBase = 1 } } }, Guid.NewGuid());
        Assert.Equal(HttpStatusCode.Conflict, twice.Status);

        // Cross-tenant: an Alpha admin cannot see or dispense the Beta prescription.
        using var alpha = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.NotFound, (await Send(alpha, HttpMethod.Get, $"/api/v1/inventory/pharmacy/prescriptions/{rxId}", null)).Status);
        Assert.Equal(HttpStatusCode.NotFound, (await Send(alpha, HttpMethod.Post, "/api/v1/inventory/pharmacy/dispenses",
            new { consultationId = rxId, storeId, lines = new[] { new { lineNo = 1, qtyBase = 1 } } }, Guid.NewGuid())).Status);

        // Roles without pharmacy access are refused before the database.
        using var reception = factory.ClientAs(AlphaReception, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(reception, HttpMethod.Get, "/api/v1/inventory/pharmacy/queue", null)).Status);
        using var doctor = factory.ClientAs(BetaDoctor, Beta);
        Assert.Equal(HttpStatusCode.Forbidden, (await Send(doctor, HttpMethod.Post, "/api/v1/inventory/pharmacy/dispenses",
            new { consultationId = rxId, storeId, lines = new[] { new { lineNo = 1, qtyBase = 1 } } }, Guid.NewGuid())).Status);
    }

    private async Task<string> FinalizedPrescriptionAsync(string itemId)
    {
        await using (var conn = new NpgsqlConnection(AdminConnection))
        {
            await conn.OpenAsync();
            await using var reg = new NpgsqlCommand(
                "update appointment.practitioners set registration_number = coalesce(nullif(btrim(registration_number), ''), 'NMC/2000001') where id = @id", conn);
            reg.Parameters.AddWithValue("id", BetaDoctorPractitioner);
            await reg.ExecuteNonQueryAsync();
        }

        var queueEntryId = Guid.NewGuid();
        await using (var conn = new NpgsqlConnection(AdminConnection))
        {
            await conn.OpenAsync();
            await using var cmd = new NpgsqlCommand(
                """
                insert into appointment.queue_entries (id, tenant_id, branch_id, queue_date, token_no, patient_id, practitioner_id, status)
                values (@id, @t, @b, date '2036-01-01' + (random() * 3000)::int, 5000 + (random() * 90000)::int, @p, @pr, 'waiting')
                """, conn);
            cmd.Parameters.AddWithValue("id", queueEntryId);
            cmd.Parameters.AddWithValue("t", Beta);
            cmd.Parameters.AddWithValue("b", BetaMain);
            cmd.Parameters.AddWithValue("p", BetaPatient2);
            cmd.Parameters.AddWithValue("pr", BetaDoctorPractitioner);
            await cmd.ExecuteNonQueryAsync();
        }

        using var doctor = factory.ClientAs(BetaDoctor, Beta);
        var id = (await Send(doctor, HttpMethod.Post, "/api/v1/consultations", new { queueEntryId })).Body.GetProperty("id").GetString()!;
        var saved = await Send(doctor, HttpMethod.Put, $"/api/v1/consultations/{id}", new
        {
            rowVersion = 1,
            chiefComplaint = "Zz-QA cough (synthetic)",
            lines = new[] { new { medicineName = "Amoxicillin", strength = "500 mg", dose = "1 cap", frequency = "1-0-1", durationDays = 5, inventoryItemId = itemId } },
        });
        Assert.Equal(HttpStatusCode.OK, saved.Status);
        var fin = await Send(doctor, HttpMethod.Post, $"/api/v1/consultations/{id}/finalize", new { rowVersion = saved.Body.GetProperty("rowVersion").GetInt32() });
        Assert.Equal(HttpStatusCode.OK, fin.Status);
        return id;
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Send(HttpClient client, HttpMethod method, string path, object? body, Guid? key = null)
    {
        using var request = new HttpRequestMessage(method, path) { Content = body is null ? null : JsonContent.Create(body) };
        if (key is { } k)
        {
            request.Headers.TryAddWithoutValidation("Idempotency-Key", k.ToString());
        }

        var response = await client.SendAsync(request);
        var text = await response.Content.ReadAsStringAsync();
        return (response.StatusCode, string.IsNullOrWhiteSpace(text) ? default : JsonDocument.Parse(text).RootElement.Clone());
    }
}
