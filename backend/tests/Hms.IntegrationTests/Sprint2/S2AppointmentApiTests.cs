using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2;

/// <summary>Sprint 2.2 practitioners / schedules / slots / appointments against real PostgreSQL.</summary>
[Trait("Category", "Database")]
public sealed class S2AppointmentApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Overlapping_booking_is_409_and_back_to_back_is_fine()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var pr = await S2.CreatePractitionerAsync(admin);
        var p1 = await S2.CreatePatientAsync(admin, AlphaMain);
        var p2 = await S2.CreatePatientAsync(admin, AlphaMain);
        var start = S2.FutureSlot(1, 9, 0);

        var first = await S2.BookAsync(admin, AlphaMain, pr.Id, p1.Id, start, 30);
        Assert.Equal(HttpStatusCode.Created, first.StatusCode);
        var booked = (await first.Content.ReadFromJsonAsync<S2Appointment>())!;
        Assert.Equal("booked", booked.Status);
        Assert.Equal(start.ToUniversalTime(), booked.StartsAt);

        var overlap = await S2.BookAsync(admin, AlphaEast, pr.Id, p2.Id, start.AddMinutes(15), 30); // other branch, same practitioner
        Assert.Equal(HttpStatusCode.Conflict, overlap.StatusCode);
        Assert.Equal("appointment_overlap", await S2.CodeAsync(overlap));

        Assert.Equal(HttpStatusCode.Created, (await S2.BookAsync(admin, AlphaMain, pr.Id, p2.Id, start.AddMinutes(30), 15)).StatusCode);
        Assert.Equal(2, await S2.AppointmentCountAsync(pr.Id));
    }

    [Fact]
    public async Task Db_exclusion_constraint_is_the_backstop_for_concurrent_bookings()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var pr = await S2.CreatePractitionerAsync(admin);
        var patients = new List<S2Patient>();
        for (var i = 0; i < 6; i++)
        {
            patients.Add(await S2.CreatePatientAsync(admin, AlphaMain));
        }

        var start = S2.FutureSlot(2, 11, 0);
        var responses = await Task.WhenAll(patients.Select(p => S2.BookAsync(factory.ClientAs(AlphaAdmin, Alpha), AlphaMain, pr.Id, p.Id, start, 20)));
        Assert.Single(responses, r => r.StatusCode == HttpStatusCode.Created);
        Assert.All(responses.Where(r => r.StatusCode != HttpStatusCode.Created), r => Assert.Equal(HttpStatusCode.Conflict, r.StatusCode));
        Assert.Equal(1, await S2.AppointmentCountAsync(pr.Id));
    }

    [Fact]
    public async Task Cancel_frees_the_slot_and_terminal_states_are_409()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var pr = await S2.CreatePractitionerAsync(admin);
        var patient = await S2.CreatePatientAsync(admin, AlphaMain);
        var start = S2.FutureSlot(3);
        var appt = (await (await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, start)).Content.ReadFromJsonAsync<S2Appointment>())!;

        var cancel = await admin.PostAsJsonAsync($"/api/v1/appointments/{appt.Id}/cancel", new { reason = "Patient called" });
        Assert.Equal(HttpStatusCode.OK, cancel.StatusCode);
        var cancelled = (await cancel.Content.ReadFromJsonAsync<S2Appointment>())!;
        Assert.Equal("cancelled", cancelled.Status);
        Assert.Equal("Patient called", cancelled.CancelReason);
        Assert.NotNull(cancelled.CancelledAt); // trigger-owned timestamp, reloaded

        var again = await admin.PostAsJsonAsync($"/api/v1/appointments/{appt.Id}/cancel", new { });
        Assert.Equal(HttpStatusCode.Conflict, again.StatusCode);
        Assert.Equal("invalid_transition", await S2.CodeAsync(again));
        Assert.Equal(HttpStatusCode.Conflict, (await admin.PostAsJsonAsync($"/api/v1/appointments/{appt.Id}/reschedule", new { startsAt = start.AddHours(1), endsAt = start.AddHours(1).AddMinutes(15) })).StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, (await admin.PostAsync($"/api/v1/appointments/{appt.Id}/no-show", null)).StatusCode);

        Assert.Equal(HttpStatusCode.Created, (await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, start)).StatusCode); // time freed
    }

    [Fact]
    public async Task Reschedule_into_an_overlap_is_409_and_otherwise_moves_the_booking()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var pr = await S2.CreatePractitionerAsync(admin);
        var patient = await S2.CreatePatientAsync(admin, AlphaMain);
        var a = (await (await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, S2.FutureSlot(4, 9))).Content.ReadFromJsonAsync<S2Appointment>())!;
        _ = await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, S2.FutureSlot(4, 10));

        var clash = await admin.PostAsJsonAsync($"/api/v1/appointments/{a.Id}/reschedule", new { startsAt = S2.FutureSlot(4, 10, 5), endsAt = S2.FutureSlot(4, 10, 20) });
        Assert.Equal(HttpStatusCode.Conflict, clash.StatusCode);
        Assert.Equal("appointment_overlap", await S2.CodeAsync(clash));

        var moved = await admin.PostAsJsonAsync($"/api/v1/appointments/{a.Id}/reschedule", new { startsAt = S2.FutureSlot(4, 11), endsAt = S2.FutureSlot(4, 11, 30) });
        Assert.Equal(HttpStatusCode.OK, moved.StatusCode);
        Assert.Equal(S2.FutureSlot(4, 11).ToUniversalTime(), (await moved.Content.ReadFromJsonAsync<S2Appointment>())!.StartsAt);
    }

    [Fact]
    public async Task Writes_are_bound_to_the_branch_and_other_tenants_get_404()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        using var receptionMain = factory.ClientAs(AlphaReception, Alpha); // receptionist @Main only
        var pr = await S2.CreatePractitionerAsync(admin);
        var patient = await S2.CreatePatientAsync(admin, AlphaMain);

        Assert.Equal(HttpStatusCode.Forbidden, (await S2.BookAsync(receptionMain, AlphaEast, pr.Id, patient.Id, S2.FutureSlot(6))).StatusCode);
        var atEast = (await (await S2.BookAsync(admin, AlphaEast, pr.Id, patient.Id, S2.FutureSlot(6, 12))).Content.ReadFromJsonAsync<S2Appointment>())!;
        Assert.Equal(HttpStatusCode.Forbidden, (await receptionMain.PostAsJsonAsync($"/api/v1/appointments/{atEast.Id}/cancel", new { })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await receptionMain.GetAsync($"/api/v1/appointments/{atEast.Id}")).StatusCode); // reads tenant-wide (D10)
        Assert.Equal(HttpStatusCode.Created, (await S2.BookAsync(receptionMain, AlphaMain, pr.Id, patient.Id, S2.FutureSlot(7, 14))).StatusCode); // Main on another day (one branch per day)

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync($"/api/v1/appointments/{atEast.Id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PostAsJsonAsync($"/api/v1/appointments/{atEast.Id}/cancel", new { })).StatusCode);
        var list = await beta.GetFromJsonAsync<S2Page<S2Appointment>>($"/api/v1/appointments?practitionerId={pr.Id}");
        Assert.Empty(list!.Items);

        // Contract v4: foreign ids are 404 everywhere (DB P0002), same-tenant out-of-scope is 403.
        var crossTenant = await S2.BookAsync(beta, BetaMain, pr.Id, patient.Id, S2.FutureSlot(6, 16));
        Assert.Equal(HttpStatusCode.NotFound, crossTenant.StatusCode);
        Assert.Equal("not_found", await S2.CodeAsync(crossTenant));
        Assert.Equal(HttpStatusCode.NotFound, (await S2.BookAsync(beta, AlphaMain, pr.Id, patient.Id, S2.FutureSlot(6, 17))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await S2.BookAsync(admin, AlphaMain, pr.Id, BetaPatientId, S2.FutureSlot(7, 18))).StatusCode);
        Assert.Equal(2, await S2.AppointmentCountAsync(pr.Id));
    }

    [Fact]
    public async Task Booking_a_soft_deleted_patient_is_rejected()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var pr = await S2.CreatePractitionerAsync(admin);
        var patient = await S2.CreatePatientAsync(admin, AlphaMain);
        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync($"/api/v1/patients/{patient.Id}")).StatusCode);

        var response = await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, S2.FutureSlot(7));
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        Assert.Equal(0, await S2.AppointmentCountAsync(pr.Id));
    }

    [Fact]
    public async Task Schedules_are_admin_only_overlaps_are_409_and_slots_exclude_bookings()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        var pr = await S2.CreatePractitionerAsync(admin);
        var body = new { practitionerId = pr.Id, branchId = AlphaMain, weekday = 1, startTime = "09:00", endTime = "10:00", slotMinutes = 15, validFrom = "2031-01-01" };

        Assert.Equal(HttpStatusCode.Forbidden, (await reception.PostAsJsonAsync("/api/v1/schedules", body)).StatusCode);
        var created = await admin.PostAsJsonAsync("/api/v1/schedules", body);
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var schedule = (await created.Content.ReadFromJsonAsync<S2Schedule>())!;
        Assert.Equal("09:00", schedule.StartTime);

        var overlap2 = await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = pr.Id, branchId = AlphaEast, weekday = 1, startTime = "09:30", endTime = "11:00", validFrom = "2031-01-01" });
        Assert.Equal(HttpStatusCode.Conflict, overlap2.StatusCode);
        Assert.Equal("schedule_overlap", await S2.CodeAsync(overlap2));

        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = pr.Id, branchId = AlphaMain, weekday = 8, startTime = "10:00", endTime = "09:00" })).StatusCode);

        // 2031-03-03 is a Monday: 4 slots 09:00-10:00 IST, minus one booking at 09:15.
        var patient = await S2.CreatePatientAsync(admin, AlphaMain);
        Assert.Equal(HttpStatusCode.Created, (await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, S2.FutureSlot(0, 9, 15))).StatusCode);
        var slots = await reception.GetFromJsonAsync<List<S2Slot>>($"/api/v1/slots?branchId={AlphaMain}&from=2031-03-03&to=2031-03-03&practitionerId={pr.Id}");
        Assert.Equal(
            new[] { S2.FutureSlot(0, 9, 0), S2.FutureSlot(0, 9, 30), S2.FutureSlot(0, 9, 45) }.Select(d => d.ToUniversalTime()),
            slots!.Select(s => s.StartsAt));

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync($"/api/v1/slots?branchId={AlphaMain}&from=2031-03-03")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync($"/api/v1/slots?branchId={BetaMain}&from=2031-03-03&practitionerId={pr.Id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = pr.Id, branchId = BetaMain, weekday = 2, startTime = "09:00", endTime = "10:00" })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = pr.Id, branchId = BetaMain, weekday = 2, startTime = "09:00", endTime = "10:00" })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PatchAsJsonAsync($"/api/v1/schedules/{schedule.Id}", new { isActive = false })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await reception.GetAsync($"/api/v1/slots?branchId={AlphaMain}&from=2031-03-03&to=2031-05-03")).StatusCode);

        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync($"/api/v1/schedules/{schedule.Id}")).StatusCode);
        Assert.Empty((await reception.GetFromJsonAsync<List<S2Slot>>($"/api/v1/slots?branchId={AlphaMain}&from=2031-03-03&practitionerId={pr.Id}"))!);
    }

    [Fact]
    public async Task Practitioners_are_admin_managed_and_tenant_scoped()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        Assert.Equal(HttpStatusCode.Forbidden, (await reception.PostAsJsonAsync("/api/v1/practitioners", new { displayName = "Nope" })).StatusCode);
        var pr = await S2.CreatePractitionerAsync(admin);
        Assert.Contains((await reception.GetFromJsonAsync<List<S2Practitioner>>("/api/v1/practitioners"))!, p => p.Id == pr.Id);

        var deactivate = await admin.PatchAsJsonAsync($"/api/v1/practitioners/{pr.Id}", new { isActive = false });
        Assert.False((await deactivate.Content.ReadFromJsonAsync<S2Practitioner>())!.IsActive);
        var patient = await S2.CreatePatientAsync(admin, AlphaMain);
        Assert.Equal(HttpStatusCode.BadRequest, (await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, S2.FutureSlot(8))).StatusCode); // practitioner_inactive

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.DoesNotContain((await beta.GetFromJsonAsync<List<S2Practitioner>>("/api/v1/practitioners?activeOnly=false"))!, p => p.Id == pr.Id);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PatchAsJsonAsync($"/api/v1/practitioners/{pr.Id}", new { displayName = "Stolen" })).StatusCode);
    }
}
