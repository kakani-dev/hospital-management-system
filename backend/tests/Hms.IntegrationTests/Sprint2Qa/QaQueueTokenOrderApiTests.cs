using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2Qa;

/// <summary>
/// OPD queue token order (contract §3.1-3.3, §A.6, D6, D7, D11): tokens count from 1 per
/// (tenant, branch, branch-local date), shared by appointment check-ins and walk-ins, allocated
/// atomically; the board is ordered by tokenNo. Each test creates its own branch, so its counter
/// starts empty and the expected tokens are exact.
/// </summary>
[Trait("Category", "Database")]
public sealed class QaQueueTokenOrderApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static async Task<List<QaQueueEntry>> BoardAsync(HttpClient client, Guid branch, string? status = null) =>
        await Qa.ReadAsync<List<QaQueueEntry>>(
            await client.GetAsync($"{QaRoutes.Queue}?branchId={branch}" + (status is null ? string.Empty : $"&status={status}")), HttpStatusCode.OK);

    [Fact]
    public async Task Tokens_start_at_1_and_follow_check_in_order_across_appointments_and_walk_ins()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var branch = await Qa.CreateBranchAsync(admin);
        var receptionist = await CreateUserAsync("s2qa-tok-rcp", (Alpha, branch.Id, "receptionist"));
        using var desk = factory.ClientAs(receptionist, Alpha);
        var practitioner = await Qa.CreatePractitionerAsync(admin);
        var today = await Qa.BranchTodayAsync(branch.Id);

        var p = new List<QaPatient>();
        for (var i = 0; i < 4; i++)
        {
            p.Add(await Qa.CreatePatientAsync(admin, branch.Id, "Token", Qa.NewSurname($"T{i}")));
        }

        // Appointment order (by time) differs from arrival order on purpose: tokens follow arrival.
        var early = await Qa.BookOkAsync(desk, branch.Id, practitioner.Id, p[0].Id, await Qa.BranchTodayAtAsync(branch.Id, 1), 10);
        var late = await Qa.BookOkAsync(desk, branch.Id, practitioner.Id, p[1].Id, await Qa.BranchTodayAtAsync(branch.Id, 30), 10);

        var t1 = await Qa.CheckInOkAsync(desk, late.Id);
        var t2 = await Qa.WalkInOkAsync(desk, branch.Id, p[2].Id);
        var t3 = await Qa.CheckInOkAsync(desk, early.Id);
        var t4 = await Qa.WalkInOkAsync(desk, branch.Id, p[3].Id, practitioner.Id);

        Assert.Equal<int>([1, 2, 3, 4], new[] { t1.TokenNo, t2.TokenNo, t3.TokenNo, t4.TokenNo });
        Assert.All(new[] { t1, t2, t3, t4 }, t => Assert.Equal(today, t.QueueDate));
        Assert.All(new[] { t1, t2, t3, t4 }, t => Assert.Equal((t.QueueEntryId, t.TokenNo, "waiting"), (t.Entry.Id, t.Entry.TokenNo, t.Entry.Status)));
        Assert.Equal((late.Id, (Guid?)practitioner.Id), (t1.Entry.AppointmentId, t1.Entry.PractitionerId)); // defaults to the appointment's
        Assert.Null(t2.Entry.AppointmentId); // walk-in...
        Assert.Null(t2.Entry.PractitionerId); // ...any doctor
        Assert.Equal("checked_in", await Qa.AppointmentStatusAsync(late.Id));

        var board = await BoardAsync(desk, branch.Id);
        Assert.Equal<int>([1, 2, 3, 4], board.Select(e => e.TokenNo));
        Assert.Equal<Guid>([p[1].Id, p[2].Id, p[0].Id, p[3].Id], board.Select(e => e.PatientId));
        Assert.All(board, e => Assert.Equal((branch.Id, today), (e.BranchId, e.QueueDate)));

        // API v2: the patient summary is embedded on queue entries and appointments.
        Assert.Equal(new QaPatientRef(p[1].Id, p[1].Mrn, p[1].FirstName, p[1].LastName), board[0].Patient);
        Assert.Equal(p[1].Mrn, t1.Entry.Patient?.Mrn);
        Assert.Equal(p[0].Mrn, (await Qa.ReadAsync<QaAppointment>(await desk.GetAsync(QaRoutes.Appointment(early.Id)), HttpStatusCode.OK)).Patient?.Mrn);
    }

    [Fact]
    public async Task Board_keeps_token_order_through_status_changes_and_filters_by_status()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var branch = await Qa.CreateBranchAsync(admin);
        var entries = new List<QaCheckIn>();
        for (var i = 0; i < 4; i++)
        {
            var patient = await Qa.CreatePatientAsync(admin, branch.Id, "Board", Qa.NewSurname($"B{i}"));
            entries.Add(await Qa.WalkInOkAsync(admin, branch.Id, patient.Id));
        }

        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync(QaRoutes.QueueEntry(entries[2].QueueEntryId), new { status = "in_consultation" })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync(QaRoutes.QueueEntry(entries[0].QueueEntryId), new { status = "cancelled" })).StatusCode);

        var board = await BoardAsync(admin, branch.Id);
        Assert.Equal<int>([1, 2, 3, 4], board.Select(e => e.TokenNo));
        Assert.Equal<string>(["cancelled", "waiting", "in_consultation", "waiting"], board.Select(e => e.Status));
        Assert.Equal<int>([2, 4], (await BoardAsync(admin, branch.Id, "waiting")).Select(e => e.TokenNo));

        // Invalid transitions are 409 and change nothing.
        var bad = await admin.PatchAsJsonAsync(QaRoutes.QueueEntry(entries[0].QueueEntryId), new { status = "in_consultation" });
        Assert.Equal(HttpStatusCode.Conflict, bad.StatusCode);
        Assert.Equal(QaCodes.InvalidTransition, await Qa.CodeAsync(bad));
        var skip = await admin.PatchAsJsonAsync(QaRoutes.QueueEntry(entries[1].QueueEntryId), new { status = "done" });
        Assert.Equal(HttpStatusCode.Conflict, skip.StatusCode);
        Assert.Equal("waiting", (await BoardAsync(admin, branch.Id)).Single(e => e.TokenNo == 2).Status);
    }

    [Fact]
    public async Task Each_branch_has_its_own_counter_and_a_patient_can_rejoin_after_done_with_a_new_token()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var north = await Qa.CreateBranchAsync(admin);
        var south = await Qa.CreateBranchAsync(admin);
        var patient = await Qa.CreatePatientAsync(admin, north.Id, "Two", Qa.NewSurname("Branches"));
        var other = await Qa.CreatePatientAsync(admin, north.Id, "Other", Qa.NewSurname("Branches"));

        var n1 = await Qa.WalkInOkAsync(admin, north.Id, patient.Id);
        var s1 = await Qa.WalkInOkAsync(admin, south.Id, patient.Id); // one active entry per BRANCH (D11)
        var n2 = await Qa.WalkInOkAsync(admin, north.Id, other.Id);
        Assert.Equal((1, 1, 2), (n1.TokenNo, s1.TokenNo, n2.TokenNo));

        // Still waiting at north: a second check-in is 409 already_checked_in (D11).
        var again = await admin.PostAsJsonAsync(QaRoutes.WalkIn, new { branchId = north.Id, patientId = patient.Id });
        Assert.Equal(HttpStatusCode.Conflict, again.StatusCode);
        Assert.Equal(QaCodes.AlreadyCheckedIn, await Qa.CodeAsync(again));

        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync(QaRoutes.QueueEntry(n1.QueueEntryId), new { status = "in_consultation" })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync(QaRoutes.QueueEntry(n1.QueueEntryId), new { status = "done" })).StatusCode);
        var rejoin = await Qa.WalkInOkAsync(admin, north.Id, patient.Id);
        Assert.True(rejoin.TokenNo > n2.TokenNo, $"rejoin token {rejoin.TokenNo} must come after {n2.TokenNo}");
        Assert.Equal<int>([1, 2, rejoin.TokenNo], (await BoardAsync(admin, north.Id)).Select(e => e.TokenNo));
    }

    [Fact]
    public async Task Concurrent_check_ins_get_distinct_consecutive_tokens()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var branch = await Qa.CreateBranchAsync(admin);
        const int n = 8;
        var patients = new List<QaPatient>();
        for (var i = 0; i < n; i++)
        {
            patients.Add(await Qa.CreatePatientAsync(admin, branch.Id, "Rush", Qa.NewSurname($"R{i}")));
        }

        var clients = patients.Select(_ => factory.ClientAs(AlphaAdmin, Alpha)).ToList();
        try
        {
            var results = await Task.WhenAll(patients.Select((p, i) => Qa.WalkInOkAsync(clients[i], branch.Id, p.Id)));
            Assert.Equal(Enumerable.Range(1, n), results.Select(r => r.TokenNo).Order());
        }
        finally
        {
            clients.ForEach(c => c.Dispose());
        }

        Assert.Equal(Enumerable.Range(1, n), (await BoardAsync(admin, branch.Id)).Select(e => e.TokenNo));
    }

    [Fact]
    public async Task Queue_date_is_the_branch_local_date()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        // UTC+14 and UTC-11: at most hours of the day these are on different calendar dates.
        var kiritimati = await Qa.CreateBranchAsync(admin, "Pacific/Kiritimati");
        var pagoPago = await Qa.CreateBranchAsync(admin, "Pacific/Pago_Pago");
        var patient = await Qa.CreatePatientAsync(admin, kiritimati.Id, "Zone", Qa.NewSurname("Date"));

        var east = await Qa.WalkInOkAsync(admin, kiritimati.Id, patient.Id);
        var west = await Qa.WalkInOkAsync(admin, pagoPago.Id, patient.Id);
        Assert.Equal(await Qa.BranchTodayAsync(kiritimati.Id), east.QueueDate);
        Assert.Equal(await Qa.BranchTodayAsync(pagoPago.Id), west.QueueDate);
        Assert.Equal(1, east.TokenNo);
        Assert.Equal(1, west.TokenNo);

        // Default board date is the branch-local today.
        Assert.Equal(east.QueueEntryId, Assert.Single(await BoardAsync(admin, kiritimati.Id)).Id);
    }
}
