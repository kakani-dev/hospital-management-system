using System.Net;
using System.Net.Http.Json;
using Hms.Gateway.Infrastructure;
using Hms.SharedKernel.Messaging;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2;

/// <summary>Sprint 2.3 check-in / OPD queue and 2.4 outbox (trigger-written, same transaction) against real PostgreSQL.</summary>
[Trait("Category", "Database")]
public sealed class S2QueueAndOutboxApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static async Task<(S2Practitioner Practitioner, S2Patient Patient, S2Appointment Appointment)> BookTodayAsync(HttpClient admin, Guid branch)
    {
        var pr = await S2.CreatePractitionerAsync(admin);
        var patient = await S2.CreatePatientAsync(admin, branch);
        var response = await S2.BookAsync(admin, branch, pr.Id, patient.Id, S2.TodayAt(12), 20);
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        return (pr, patient, (await response.Content.ReadFromJsonAsync<S2Appointment>())!);
    }

    [Fact]
    public async Task Check_in_issues_a_token_once_and_the_queue_drives_the_appointment()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var receptionEast = await CreateUserAsync("s2-q-reception", (Alpha, AlphaEast, "receptionist"));
        var doctorEast = await CreateUserAsync("s2-q-doctor", (Alpha, AlphaEast, "doctor"));
        using var reception = factory.ClientAs(receptionEast, Alpha);
        using var doctor = factory.ClientAs(doctorEast, Alpha);
        var (pr, patient, appt) = await BookTodayAsync(admin, AlphaEast);

        Assert.Equal(HttpStatusCode.Forbidden, (await doctor.PostAsync($"/api/v1/appointments/{appt.Id}/check-in", null)).StatusCode);

        var checkIn = await reception.PostAsync($"/api/v1/appointments/{appt.Id}/check-in", null);
        Assert.Equal(HttpStatusCode.Created, checkIn.StatusCode);
        var result = (await checkIn.Content.ReadFromJsonAsync<S2CheckIn>())!;
        Assert.True(result.TokenNo > 0);
        Assert.Equal("waiting", result.Entry.Status);
        Assert.Equal(appt.Id, result.Entry.AppointmentId);
        Assert.Equal("checked_in", (await admin.GetFromJsonAsync<S2Appointment>($"/api/v1/appointments/{appt.Id}"))!.Status);

        var again = await reception.PostAsync($"/api/v1/appointments/{appt.Id}/check-in", null);
        Assert.Equal(HttpStatusCode.Conflict, again.StatusCode);
        Assert.Equal("already_checked_in", await S2.CodeAsync(again));

        var board = (await reception.GetFromJsonAsync<List<S2QueueEntry>>($"/api/v1/queue?branchId={AlphaEast}"))!;
        Assert.Contains(board!, q => q.Id == result.QueueEntryId && q.TokenNo == result.TokenNo);
        Assert.Equal(board!.Select(q => q.TokenNo).Order(), board.Select(q => q.TokenNo));

        // Doctor may call in / finish but not cancel; receptionist may do everything.
        Assert.Equal(HttpStatusCode.Forbidden, (await doctor.PatchAsJsonAsync($"/api/v1/queue/{result.QueueEntryId}", new { status = "cancelled" })).StatusCode);
        var call = await doctor.PatchAsJsonAsync($"/api/v1/queue/{result.QueueEntryId}", new { status = "in_consultation" });
        Assert.Equal(HttpStatusCode.OK, call.StatusCode);
        Assert.Equal("in_consultation", (await admin.GetFromJsonAsync<S2Appointment>($"/api/v1/appointments/{appt.Id}"))!.Status);
        Assert.Equal(HttpStatusCode.OK, (await doctor.PatchAsJsonAsync($"/api/v1/queue/{result.QueueEntryId}", new { status = "done" })).StatusCode);
        Assert.Equal("completed", (await admin.GetFromJsonAsync<S2Appointment>($"/api/v1/appointments/{appt.Id}"))!.Status);

        var invalid = await reception.PatchAsJsonAsync($"/api/v1/queue/{result.QueueEntryId}", new { status = "in_consultation" });
        Assert.Equal(HttpStatusCode.Conflict, invalid.StatusCode);
        Assert.Equal("invalid_transition", await S2.CodeAsync(invalid));
        Assert.Equal(HttpStatusCode.BadRequest, (await reception.PatchAsJsonAsync($"/api/v1/queue/{result.QueueEntryId}", new { status = "waiting" })).StatusCode);

        // Outbox: booked, checked_in, in_consultation, completed + queue events, all written by triggers.
        Assert.Equal(1, await S2.OutboxCountAsync(pr.Id, "appointment.booked"));
        Assert.Equal(1, await S2.OutboxCountAsync(pr.Id, "appointment.checked_in"));
        Assert.Equal(1, await S2.OutboxCountAsync(pr.Id, "appointment.completed"));
        _ = patient;
    }

    [Fact]
    public async Task Check_in_and_board_are_branch_bound_and_tenant_isolated()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        using var receptionMain = factory.ClientAs(AlphaReception, Alpha); // receptionist @Main only
        var (_, _, appt) = await BookTodayAsync(admin, AlphaEast);

        Assert.Equal(HttpStatusCode.Forbidden, (await receptionMain.PostAsync($"/api/v1/appointments/{appt.Id}/check-in", null)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await receptionMain.GetAsync($"/api/v1/queue?branchId={AlphaEast}")).StatusCode);

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PostAsync($"/api/v1/appointments/{appt.Id}/check-in", null)).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync($"/api/v1/queue?branchId={AlphaEast}")).StatusCode); // foreign branch (v4)
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PostAsJsonAsync("/api/v1/queue/walk-in", new { branchId = AlphaEast, patientId = BetaPatientId })).StatusCode);

        var entry = (await (await admin.PostAsync($"/api/v1/appointments/{appt.Id}/check-in", null)).Content.ReadFromJsonAsync<S2CheckIn>())!;
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PatchAsJsonAsync($"/api/v1/queue/{entry.QueueEntryId}", new { status = "cancelled" })).StatusCode);
        // Same tenant, branch outside scope: 403 (v4: 42501), not 404.
        Assert.Equal(HttpStatusCode.Forbidden, (await receptionMain.PatchAsJsonAsync($"/api/v1/queue/{entry.QueueEntryId}", new { status = "cancelled" })).StatusCode);
        var betaBoard = await beta.GetFromJsonAsync<List<S2QueueEntry>>($"/api/v1/queue?branchId={BetaMain}");
        Assert.DoesNotContain(betaBoard!, q => q.Id == entry.QueueEntryId);
    }

    [Fact]
    public async Task Walk_in_gets_the_next_token_and_one_active_entry_per_patient()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var nurseMain = await CreateUserAsync("s2-walkin-nurse", (Alpha, AlphaMain, "nurse"));
        using var nurse = factory.ClientAs(nurseMain, Alpha);
        var p1 = await S2.CreatePatientAsync(admin, AlphaMain);
        var p2 = await S2.CreatePatientAsync(admin, AlphaMain);

        var first = await nurse.PostAsJsonAsync("/api/v1/queue/walk-in", new { branchId = AlphaMain, patientId = p1.Id });
        Assert.Equal(HttpStatusCode.Created, first.StatusCode);
        var t1 = (await first.Content.ReadFromJsonAsync<S2CheckIn>())!;
        Assert.Null(t1.Entry.AppointmentId);
        var t2 = (await (await nurse.PostAsJsonAsync("/api/v1/queue/walk-in", new { branchId = AlphaMain, patientId = p2.Id })).Content.ReadFromJsonAsync<S2CheckIn>())!;
        Assert.True(t2.TokenNo > t1.TokenNo);

        var dup = await nurse.PostAsJsonAsync("/api/v1/queue/walk-in", new { branchId = AlphaMain, patientId = p1.Id });
        Assert.Equal(HttpStatusCode.Conflict, dup.StatusCode);
        Assert.Equal("already_checked_in", await S2.CodeAsync(dup));

        Assert.Equal(HttpStatusCode.Forbidden, (await nurse.PostAsJsonAsync("/api/v1/queue/walk-in", new { branchId = AlphaEast, patientId = p1.Id })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await nurse.PostAsJsonAsync("/api/v1/queue/walk-in", new { branchId = AlphaMain, patientId = BetaPatientId })).StatusCode);
        using var lab = factory.ClientAs(AlphaLab, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.PostAsJsonAsync("/api/v1/queue/walk-in", new { branchId = AlphaMain, patientId = p2.Id })).StatusCode);

        // After cancelling, the patient can queue again.
        Assert.Equal(HttpStatusCode.OK, (await nurse.PatchAsJsonAsync($"/api/v1/queue/{t1.QueueEntryId}", new { status = "cancelled" })).StatusCode);
        Assert.Equal(HttpStatusCode.Created, (await nurse.PostAsJsonAsync("/api/v1/queue/walk-in", new { branchId = AlphaMain, patientId = p1.Id })).StatusCode);
    }

    [Fact]
    public async Task Outbox_row_exists_only_when_the_business_change_commits()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var pr = await S2.CreatePractitionerAsync(admin);
        var p1 = await S2.CreatePatientAsync(admin, AlphaMain);
        var p2 = await S2.CreatePatientAsync(admin, AlphaMain);
        var start = S2.FutureSlot(9, 15);

        var ok = await S2.BookAsync(admin, AlphaMain, pr.Id, p1.Id, start, 30);
        Assert.Equal(HttpStatusCode.Created, ok.StatusCode);
        var appt = (await ok.Content.ReadFromJsonAsync<S2Appointment>())!;
        Assert.Equal(1, await S2.OutboxCountAsync(pr.Id));
        Assert.Equal(1, await S2.ScalarLongAsync(
            "select count(*) from messaging.outbox where aggregate_id = @a and event_type = 'appointment.booked' and tenant_id = @t and payload ? 'reason' = false",
            ("a", appt.Id), ("t", Alpha)));

        // Rejected requests (overlap 409, 8h+ reschedule 400): no appointment change, no event.
        var clash = await S2.BookAsync(admin, AlphaMain, pr.Id, p2.Id, start.AddMinutes(10), 30);
        Assert.Equal(HttpStatusCode.Conflict, clash.StatusCode);
        var tooLong = await admin.PostAsJsonAsync($"/api/v1/appointments/{appt.Id}/reschedule", new { startsAt = start.AddMinutes(-60), endsAt = start.AddMinutes(-60).AddHours(9) });
        Assert.Equal(HttpStatusCode.BadRequest, tooLong.StatusCode);
        Assert.Equal(1, await S2.OutboxCountAsync(pr.Id));
        Assert.Equal(1, await S2.AppointmentCountAsync(pr.Id));

        // A committed change adds exactly one event.
        Assert.Equal(HttpStatusCode.OK, (await admin.PostAsJsonAsync($"/api/v1/appointments/{appt.Id}/cancel", new { reason = "x" })).StatusCode);
        Assert.Equal(1, await S2.OutboxCountAsync(pr.Id, "appointment.cancelled"));
        Assert.Equal(2, await S2.OutboxCountAsync(pr.Id));
    }

    [Fact]
    public async Task Failed_request_after_a_db_write_rolls_back_the_event_too()
    {
        // Check-in writes the appointment status + queue row + outbox rows in one RPC call; an
        // appointment from ANOTHER day fails with 55000 after the patient/appointment checks, inside
        // the request transaction. Nothing (status, queue entry, event) may survive.
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var pr = await S2.CreatePractitionerAsync(admin);
        var patient = await S2.CreatePatientAsync(admin, AlphaMain);
        var appt = (await (await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, S2.FutureSlot(10))).Content.ReadFromJsonAsync<S2Appointment>())!;

        var response = await admin.PostAsync($"/api/v1/appointments/{appt.Id}/check-in", null);
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
        Assert.Equal("invalid_state", await S2.CodeAsync(response));
        Assert.Equal("booked", (await admin.GetFromJsonAsync<S2Appointment>($"/api/v1/appointments/{appt.Id}"))!.Status);
        Assert.Equal(0, await S2.ScalarLongAsync("select count(*) from appointment.queue_entries where appointment_id = @a", ("a", appt.Id)));
        Assert.Equal(0, await S2.OutboxCountAsync(pr.Id, "appointment.checked_in"));
        Assert.Equal(1, await S2.OutboxCountAsync(pr.Id));
    }

    [Fact]
    public async Task Dispatcher_store_claims_completes_and_fails_as_hms_dispatcher()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var pr = await S2.CreatePractitionerAsync(admin);
        var patient = await S2.CreatePatientAsync(admin, AlphaMain);
        var a1 = (await (await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, S2.FutureSlot(11, 9))).Content.ReadFromJsonAsync<S2Appointment>())!;
        var a2 = (await (await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, S2.FutureSlot(11, 10))).Content.ReadFromJsonAsync<S2Appointment>())!;

        // The API login role (hms_api_login -> hms_api -> hms_dispatcher), exactly like the gateway.
        await using var dataSource = NpgsqlDataSource.Create(ApiConnection);
        var store = new PostgresOutboxStore(dataSource);
        var worker = $"it-{Guid.NewGuid():N}";
        OutboxMessage? m1 = null, m2 = null;
        for (var round = 0; round < 50 && (m1 is null || m2 is null); round++)
        {
            var batch = await store.ClaimAsync(worker, 500, TimeSpan.FromMinutes(5), CancellationToken.None);
            if (batch.Count == 0)
            {
                break;
            }

            foreach (var m in batch)
            {
                if (m.AggregateId == a1.Id)
                {
                    m1 = m;
                }
                else if (m.AggregateId == a2.Id)
                {
                    m2 = m;
                }
                else
                {
                    await store.CompleteAsync(m.Id, worker, CancellationToken.None); // drain other tests' events
                }
            }
        }

        Assert.NotNull(m1);
        Assert.NotNull(m2);
        Assert.Equal("appointment.booked", m1.EventType);
        Assert.DoesNotContain("Synthetic visit", m1.PayloadJson, StringComparison.Ordinal); // no PHI (reason) in the payload

        await store.CompleteAsync(m1.Id, worker, CancellationToken.None);
        await store.FailAsync(m2.Id, worker, "consumer down", TimeSpan.FromMinutes(10), CancellationToken.None);

        Assert.Equal(1, await S2.ScalarLongAsync("select count(*) from messaging.outbox where id = @id and status = 'done' and processed_at is not null", ("id", m1.Id)));
        Assert.Equal(1, await S2.ScalarLongAsync(
            "select count(*) from messaging.outbox where id = @id and status = 'pending' and available_at > now() + interval '5 minutes' and last_error = 'consumer down'",
            ("id", m2.Id)));

        // Another worker can't ack a row it doesn't own (P0002).
        var foreign = await Assert.ThrowsAsync<PostgresException>(() => store.CompleteAsync(m2.Id, "someone-else", CancellationToken.None));
        Assert.Equal("P0002", foreign.SqlState);

        // The API login role itself cannot touch the outbox table (fail closed).
        await using var conn = await dataSource.OpenConnectionAsync();
        await using var cmd = new NpgsqlCommand("select count(*) from messaging.outbox", conn);
        var denied = await Assert.ThrowsAsync<PostgresException>(() => cmd.ExecuteScalarAsync());
        Assert.Equal("42501", denied.SqlState);
    }
}
