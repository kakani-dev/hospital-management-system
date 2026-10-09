using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2;

/// <summary>PR #2 review fixes against real PostgreSQL (migration 20261010090400_pr2_review_fixes).</summary>
[Trait("Category", "Database")]
public sealed class S2ReviewFixesApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    /// <summary>
    /// MAJ-1: check-in, then POST /appointments/{id}/cancel. The queue entry must be cancelled too, so the
    /// active board no longer shows the patient and the patient can be soft-deleted (no 409 still_open).
    /// </summary>
    [Fact]
    public async Task Cancelling_a_checked_in_appointment_cancels_its_queue_entry_and_unblocks_patient_delete()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var receptionEast = await CreateUserAsync("s2-maj1-reception", (Alpha, AlphaEast, "receptionist"));
        using var reception = factory.ClientAs(receptionEast, Alpha);

        var pr = await S2.CreatePractitionerAsync(admin);
        var patient = await S2.CreatePatientAsync(admin, AlphaEast);
        var booked = await S2.BookAsync(admin, AlphaEast, pr.Id, patient.Id, S2.TodayAt(12), 20);
        Assert.Equal(HttpStatusCode.Created, booked.StatusCode);
        var appt = (await booked.Content.ReadFromJsonAsync<S2Appointment>())!;

        var checkIn = await reception.PostAsync($"/api/v1/appointments/{appt.Id}/check-in", null);
        Assert.Equal(HttpStatusCode.Created, checkIn.StatusCode);
        var entry = (await checkIn.Content.ReadFromJsonAsync<S2CheckIn>())!;
        var waiting = (await reception.GetFromJsonAsync<List<S2QueueEntry>>($"/api/v1/queue?branchId={AlphaEast}&status=waiting"))!;
        Assert.Contains(waiting, q => q.Id == entry.QueueEntryId && q.PatientId == patient.Id);

        var cancel = await reception.PostAsJsonAsync($"/api/v1/appointments/{appt.Id}/cancel", new { reason = "Patient left before consultation" });
        Assert.Equal(HttpStatusCode.OK, cancel.StatusCode);
        Assert.Equal("cancelled", (await cancel.Content.ReadFromJsonAsync<S2Appointment>())!.Status);

        // The board: the entry is cancelled, and no active (waiting / in_consultation) entry remains for the patient.
        var board = (await reception.GetFromJsonAsync<List<S2QueueEntry>>($"/api/v1/queue?branchId={AlphaEast}"))!;
        Assert.Equal("cancelled", Assert.Single(board, q => q.Id == entry.QueueEntryId).Status);
        Assert.DoesNotContain(board, q => q.PatientId == patient.Id && q.Status is "waiting" or "in_consultation");

        // Calling the cancelled entry in is an invalid transition, not a desynced appointment.
        var call = await reception.PatchAsJsonAsync($"/api/v1/queue/{entry.QueueEntryId}", new { status = "in_consultation" });
        Assert.Equal(HttpStatusCode.Conflict, call.StatusCode);
        Assert.Equal("invalid_transition", await S2.CodeAsync(call));

        // The patient can now be soft-deleted (before the fix: 409 because the queue entry stayed waiting).
        Assert.Equal(HttpStatusCode.NoContent, (await reception.DeleteAsync($"/api/v1/patients/{patient.Id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await reception.GetAsync($"/api/v1/patients/{patient.Id}")).StatusCode);

        // Restore so other tests that assert every entry on today's Alpha East board embeds a patient stay independent.
        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsync($"/api/v1/patients/{patient.Id}/restore", null)).StatusCode);

        // The queue cancellation went through the normal triggers (outbox event for the entry).
        Assert.Equal(1, await S2.ScalarLongAsync(
            "select count(*) from messaging.outbox where aggregate_id = @q and event_type = 'queue.status_changed' and payload->>'status' = 'cancelled'",
            ("q", entry.QueueEntryId)));
    }
}
