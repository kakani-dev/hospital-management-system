using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>Consultation + prescription v1 through the edge: lifecycle, concurrency, roles, tenancy, print.</summary>
[Trait("Category", "Database")]
public sealed class ConsultationApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly Guid BetaDoctorPractitioner = Guid.Parse("c2222222-0000-4000-8000-000000000001");
    private static readonly Guid BetaPatient2 = Guid.Parse("bb000000-0000-4000-8000-000000000002");

    [Fact]
    public async Task Doctor_drafts_finalizes_prints_and_corrects_a_prescription()
    {
        var queueEntryId = await CheckInAsync("waiting");
        using var doctor = factory.ClientAs(BetaDoctor, Beta);

        var started = await Send(doctor, HttpMethod.Post, "/api/v1/consultations", new { queueEntryId });
        Assert.Equal(HttpStatusCode.OK, started.Status);
        var id = started.Body.GetProperty("id").GetString()!;
        var again = await Send(doctor, HttpMethod.Post, "/api/v1/consultations", new { queueEntryId });
        Assert.Equal(id, again.Body.GetProperty("id").GetString());

        var bad = await Send(doctor, HttpMethod.Put, $"/api/v1/consultations/{id}", new
        {
            rowVersion = 1,
            lines = new[] { new { medicineName = "Paracetamol", dose = "1 tab", frequency = "1-0-1", durationDays = -2 } },
        });
        Assert.Equal(HttpStatusCode.BadRequest, bad.Status);

        var saved = await Send(doctor, HttpMethod.Put, $"/api/v1/consultations/{id}", new
        {
            rowVersion = 1,
            chiefComplaint = "Cough (synthetic)",
            diagnosisText = "URTI",
            lines = new[] { new { medicineName = "Paracetamol", strength = "500 mg", dose = "1 tab", frequency = "1-0-1", durationDays = 3, route = "oral", foodTiming = "after_food" } },
        });
        Assert.Equal(HttpStatusCode.OK, saved.Status);
        var rv = saved.Body.GetProperty("rowVersion").GetInt32();

        var stale = await Send(doctor, HttpMethod.Put, $"/api/v1/consultations/{id}", new { rowVersion = 1 });
        Assert.Equal(HttpStatusCode.Conflict, stale.Status);

        Assert.Equal(HttpStatusCode.Conflict, (await doctor.GetAsync($"/api/v1/consultations/{id}/print")).StatusCode);

        var final1 = await Send(doctor, HttpMethod.Post, $"/api/v1/consultations/{id}/finalize", new { rowVersion = rv });
        var final2 = await Send(doctor, HttpMethod.Post, $"/api/v1/consultations/{id}/finalize", new { rowVersion = rv });
        Assert.Equal(HttpStatusCode.OK, final1.Status);
        Assert.Equal(HttpStatusCode.OK, final2.Status);
        Assert.Equal("finalized", final2.Body.GetProperty("status").GetString());

        var edit = await Send(doctor, HttpMethod.Put, $"/api/v1/consultations/{id}", new { rowVersion = rv + 1 });
        Assert.Equal(HttpStatusCode.Conflict, edit.Status);

        var print = await Send(doctor, HttpMethod.Get, $"/api/v1/consultations/{id}/print", null);
        Assert.Equal(HttpStatusCode.OK, print.Status);
        Assert.False(string.IsNullOrEmpty(print.Body.GetProperty("patient").GetProperty("mrn").GetString()));

        var revision = await Send(doctor, HttpMethod.Post, $"/api/v1/consultations/{id}/revisions", new { });
        Assert.Equal(2, revision.Body.GetProperty("version").GetInt32());

        var history = await Send(doctor, HttpMethod.Get, $"/api/v1/consultations?patientId={BetaPatient2}", null);
        Assert.True(history.Body.GetArrayLength() >= 2);

        using var admin = factory.ClientAs(BetaAdmin, Beta);
        Assert.Equal(HttpStatusCode.OK, (await admin.GetAsync($"/api/v1/consultations/{id}")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await admin.PostAsJsonAsync($"/api/v1/consultations/{id}/finalize", new { rowVersion = 1 })).StatusCode);

        using var alpha = factory.ClientAs(AlphaAdmin, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.NotFound, (await alpha.GetAsync($"/api/v1/consultations/{id}")).StatusCode);
    }

    [Fact]
    public async Task Roles_without_clinical_access_and_visits_not_checked_in_are_refused()
    {
        using var reception = factory.ClientAs(AlphaReception, Alpha, AlphaMain);
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.GetAsync($"/api/v1/consultations?patientId={AlphaPatientId}")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.PostAsJsonAsync("/api/v1/consultations", new { queueEntryId = Guid.NewGuid() })).StatusCode);

        var done = await CheckInAsync("done");
        using var doctor = factory.ClientAs(BetaDoctor, Beta);
        Assert.Equal(HttpStatusCode.Conflict, (await doctor.PostAsJsonAsync("/api/v1/consultations", new { queueEntryId = done })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await doctor.PostAsJsonAsync("/api/v1/consultations", new { queueEntryId = Guid.NewGuid() })).StatusCode);
    }

    private static async Task<Guid> CheckInAsync(string status)
    {
        var id = Guid.NewGuid();
        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(
            """
            insert into appointment.queue_entries (id, tenant_id, branch_id, queue_date, token_no, patient_id, practitioner_id, status)
            values (@id, @t, @b, date '2036-01-01' + (random() * 3000)::int, 5000 + (random() * 90000)::int, @p, @pr, @s)
            """, conn);
        cmd.Parameters.AddWithValue("id", id);
        cmd.Parameters.AddWithValue("t", Beta);
        cmd.Parameters.AddWithValue("b", BetaMain);
        cmd.Parameters.AddWithValue("p", BetaPatient2);
        cmd.Parameters.AddWithValue("pr", BetaDoctorPractitioner);
        cmd.Parameters.AddWithValue("s", status);
        await cmd.ExecuteNonQueryAsync();
        return id;
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> Send(HttpClient client, HttpMethod method, string path, object? body)
    {
        using var request = new HttpRequestMessage(method, path) { Content = body is null ? null : JsonContent.Create(body) };
        var response = await client.SendAsync(request);
        var text = await response.Content.ReadAsStringAsync();
        return (response.StatusCode, string.IsNullOrWhiteSpace(text) ? default : JsonDocument.Parse(text).RootElement.Clone());
    }
}
