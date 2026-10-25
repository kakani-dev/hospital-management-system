using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2Qa;

/// <summary>
/// Branch write rules on the Sprint 2 endpoints (contract §0 "Branch-role binding", §A.0, D9): a write
/// needs the role AT the row's branch (tenant_admin is tenant-wide); a same-tenant branch outside the
/// caller's scope is 403 (never 404); reads stay tenant-wide except the queue board (branch-scoped, D10).
/// The fixture is the PR #1 M1 shape: billing (read-only) at Alpha Main, nurse (writer) at Alpha East.
/// </summary>
[Trait("Category", "Database")]
public sealed class QaBranchWriteRulesApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static Task<Guid> BillingAtMainNurseAtEastAsync() =>
        CreateUserAsync("s2qa-split", (Alpha, AlphaMain, "billing"), (Alpha, AlphaEast, "receptionist") /* RBAC: nurses no longer write patients */);

    [Fact]
    public async Task Patient_patch_is_tenant_wide_for_patients_edit_and_a_foreign_branch_is_404()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var atMain = await Qa.CreatePatientAsync(admin, AlphaMain, "Branch", Qa.NewSurname("Main"));
        var atEast = await Qa.CreatePatientAsync(admin, AlphaEast, "Branch", Qa.NewSurname("East"));
        var split = await BillingAtMainNurseAtEastAsync();
        using var user = factory.ClientAs(split, Alpha);

        Assert.Equal(HttpStatusCode.OK, (await user.GetAsync(QaRoutes.Patient(atMain.Id))).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await user.PatchAsJsonAsync(QaRoutes.Patient(atMain.Id), new { firstName = "Edited" })).StatusCode);
        var moved = await Qa.ReadAsync<QaPatient>(
            await user.PatchAsJsonAsync(QaRoutes.Patient(atEast.Id), new { registeredBranchId = AlphaMain }), HttpStatusCode.OK);
        Assert.Equal(AlphaMain, moved.RegisteredBranchId);
        Assert.Equal(HttpStatusCode.NotFound, (await user.PatchAsJsonAsync(QaRoutes.Patient(atMain.Id), new { registeredBranchId = BetaMain })).StatusCode);

        var billing = await CreateUserAsync("s2qa-billing-only", (Alpha, AlphaMain, "billing"));
        using var view = factory.ClientAs(billing, Alpha);
        var denied = await view.PatchAsJsonAsync(QaRoutes.Patient(atMain.Id), new { firstName = "Nope" });
        Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
        Assert.Equal(QaCodes.Forbidden, await Qa.CodeAsync(denied));
        Assert.Equal("Edited", await Qa.ScalarAsync<string>("select first_name from patient.patients where id = @id", ("id", atMain.Id)));
    }

    [Fact]
    public async Task Appointment_writes_are_bound_to_the_appointments_branch()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await Qa.CreatePractitionerAsync(admin);
        var patient = await Qa.CreatePatientAsync(admin, AlphaMain, "Appt", Qa.NewSurname("Branch"));
        var split = await BillingAtMainNurseAtEastAsync();
        using var user = factory.ClientAs(split, Alpha);

        // Book: 403 at Main (billing there), 201 at East (nurse there). Patient branch is irrelevant.
        var atMain = await Qa.BookAsync(user, AlphaMain, practitioner.Id, patient.Id, Qa.Future(hour: 9));
        Assert.Equal(HttpStatusCode.Forbidden, atMain.StatusCode);
        Assert.Equal(QaCodes.Forbidden, await Qa.CodeAsync(atMain));
        Assert.Equal(0, await Qa.AppointmentCountAsync(practitioner.Id));
        // another day: a practitioner works at one branch per day (working-hours rule, 2026-10-20)
        var east = await Qa.BookOkAsync(user, AlphaEast, practitioner.Id, patient.Id, Qa.Future(dayOffset: 1, hour: 10));
        Assert.Equal(("booked", AlphaEast), (east.Status, east.BranchId));

        // Admin books one at Main; the split user can read it (tenant-wide) but not touch it.
        var main = await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, patient.Id, Qa.Future(hour: 11));
        Assert.Equal(HttpStatusCode.OK, (await user.GetAsync(QaRoutes.Appointment(main.Id))).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden,
            (await user.PostAsJsonAsync(QaRoutes.Reschedule(main.Id), new { startsAt = Qa.Future(hour: 14), endsAt = Qa.Future(hour: 14, minute: 15) })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await user.PostAsJsonAsync(QaRoutes.Cancel(main.Id), new { reason = "Nope" })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await user.PostAsync(QaRoutes.NoShow(main.Id), content: null)).StatusCode);
        Assert.Equal("booked", await Qa.AppointmentStatusAsync(main.Id));

        // ...but can reschedule and cancel the East one.
        Assert.Equal(HttpStatusCode.OK,
            (await user.PostAsJsonAsync(QaRoutes.Reschedule(east.Id), new { startsAt = Qa.Future(dayOffset: 1, hour: 15), endsAt = Qa.Future(dayOffset: 1, hour: 15, minute: 15) })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await user.PostAsJsonAsync(QaRoutes.Cancel(east.Id), new { reason = "Synthetic" })).StatusCode);
        Assert.Equal("cancelled", await Qa.AppointmentStatusAsync(east.Id));

        // Roles that are not REG_WRITE cannot book anywhere.
        var lab = await CreateUserAsync("s2qa-lab", (Alpha, null, "lab_technician"));
        using var labClient = factory.ClientAs(lab, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await Qa.BookAsync(labClient, AlphaEast, practitioner.Id, patient.Id, Qa.Future(hour: 16))).StatusCode);
    }

    [Fact]
    public async Task Check_in_walk_in_and_queue_board_are_bound_to_the_branch()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        using var receptionMain = factory.ClientAs(AlphaReception, Alpha); // receptionist @Main (seed)
        var practitioner = await Qa.CreatePractitionerAsync(admin);
        var patient = await Qa.CreatePatientAsync(admin, AlphaMain, "Queue", Qa.NewSurname("Branch"));
        var eastAppointment = await Qa.BookOkAsync(admin, AlphaEast, practitioner.Id, patient.Id, await Qa.BranchTodayAtAsync(AlphaEast, 1));

        // Receptionist at Main cannot see an East visit (404). East walk-in and the East board stay 403.
        Assert.Equal(HttpStatusCode.NotFound, (await receptionMain.PostAsync(QaRoutes.CheckIn(eastAppointment.Id), content: null)).StatusCode);
        Assert.Equal("booked", await Qa.AppointmentStatusAsync(eastAppointment.Id));
        Assert.Equal(HttpStatusCode.Forbidden,
            (await receptionMain.PostAsJsonAsync(QaRoutes.WalkIn, new { branchId = AlphaEast, patientId = patient.Id })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await receptionMain.GetAsync($"{QaRoutes.Queue}?branchId={AlphaEast}")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await receptionMain.GetAsync($"{QaRoutes.Queue}?branchId={AlphaMain}")).StatusCode);

        // Non-FRONT_DESK roles at the right branch cannot check in (doctor, billing).
        var doctorEast = await CreateUserAsync("s2qa-doc-east", (Alpha, AlphaEast, "doctor"));
        var billingEast = await CreateUserAsync("s2qa-bill-east", (Alpha, AlphaEast, "billing"));
        foreach (var user in new[] { doctorEast, billingEast })
        {
            using var client = factory.ClientAs(user, Alpha);
            Assert.Equal(HttpStatusCode.Forbidden, (await client.PostAsync(QaRoutes.CheckIn(eastAppointment.Id), content: null)).StatusCode);
        }

        // A nurse at East checks in; the doctor at East may call in and finish but not cancel;
        // the receptionist at Main cannot change the East entry at all.
        var nurseEast = await CreateUserAsync("s2qa-nurse-east", (Alpha, AlphaEast, "nurse"));
        using var nurse = factory.ClientAs(nurseEast, Alpha);
        var checkIn = await Qa.CheckInOkAsync(nurse, eastAppointment.Id);
        using var doctor = factory.ClientAs(doctorEast, Alpha);
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync($"/api/v1/practitioners/{practitioner.Id}", new { userId = doctorEast })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await receptionMain.PatchAsJsonAsync(QaRoutes.QueueEntry(checkIn.QueueEntryId), new { status = "in_consultation" })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await doctor.PatchAsJsonAsync(QaRoutes.QueueEntry(checkIn.QueueEntryId), new { status = "cancelled" })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await doctor.PatchAsJsonAsync(QaRoutes.QueueEntry(checkIn.QueueEntryId), new { status = "in_consultation" })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await doctor.PatchAsJsonAsync(QaRoutes.QueueEntry(checkIn.QueueEntryId), new { status = "done" })).StatusCode);
        Assert.Equal("completed", await Qa.AppointmentStatusAsync(eastAppointment.Id));
    }

    [Fact]
    public async Task Practitioners_and_schedules_are_admin_only_and_slots_need_branch_access()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        using var receptionMain = factory.ClientAs(AlphaReception, Alpha);
        var practitioner = await Qa.CreatePractitionerAsync(admin);

        Assert.Equal(HttpStatusCode.Forbidden, (await receptionMain.PostAsJsonAsync(QaRoutes.Practitioners, new { displayName = "Dr Nope (synthetic)" })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await receptionMain.PatchAsJsonAsync(QaRoutes.Practitioner(practitioner.Id), new { isActive = false })).StatusCode);
        var schedule = new { practitionerId = practitioner.Id, branchId = AlphaMain, weekday = 4, startTime = "09:00", endTime = "10:00", slotMinutes = 15 };
        Assert.Equal(HttpStatusCode.Forbidden, (await receptionMain.PostAsJsonAsync(QaRoutes.Schedules, schedule)).StatusCode);
        var created = await Qa.ReadAsync<QaSchedule>(await admin.PostAsJsonAsync(QaRoutes.Schedules, schedule), HttpStatusCode.Created);
        Assert.Equal(HttpStatusCode.Forbidden, (await receptionMain.PatchAsJsonAsync(QaRoutes.Schedule(created.Id), new { isActive = false })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await receptionMain.DeleteAsync(QaRoutes.Schedule(created.Id))).StatusCode);
        Assert.True(await Qa.ScalarAsync<bool>("select is_active from appointment.schedules where id = @id", ("id", created.Id)));

        // API v2: ?branchId= lists only practitioners with an active schedule at that branch (any branch of the tenant).
        var atMain = await Qa.ReadAsync<List<QaPractitioner>>(await receptionMain.GetAsync($"{QaRoutes.Practitioners}?branchId={AlphaMain}"), HttpStatusCode.OK);
        var atEast = await Qa.ReadAsync<List<QaPractitioner>>(await receptionMain.GetAsync($"{QaRoutes.Practitioners}?branchId={AlphaEast}"), HttpStatusCode.OK);
        Assert.Contains(atMain, p => p.Id == practitioner.Id);
        Assert.DoesNotContain(atEast, p => p.Id == practitioner.Id);
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync(QaRoutes.Schedule(created.Id), new { isActive = false })).StatusCode);
        Assert.DoesNotContain(
            await Qa.ReadAsync<List<QaPractitioner>>(await receptionMain.GetAsync($"{QaRoutes.Practitioners}?branchId={AlphaMain}"), HttpStatusCode.OK),
            p => p.Id == practitioner.Id);

        // Any member reads practitioners/schedules; slots need REG_READ and branch access.
        Assert.Equal(HttpStatusCode.OK, (await receptionMain.GetAsync(QaRoutes.Practitioners)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await receptionMain.GetAsync($"{QaRoutes.Schedules}?branchId={AlphaEast}")).StatusCode);
        var from = Qa.Future().ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        Assert.Equal(HttpStatusCode.OK, (await receptionMain.GetAsync($"{QaRoutes.Slots}?branchId={AlphaMain}&from={from}&to={from}")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await receptionMain.GetAsync($"{QaRoutes.Slots}?branchId={AlphaEast}&from={from}&to={from}")).StatusCode);
    }
}
