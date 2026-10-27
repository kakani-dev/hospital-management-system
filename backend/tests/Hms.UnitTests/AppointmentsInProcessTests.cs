using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Hms.SharedKernel.Tenancy;
using static Hms.UnitTests.InProcessApiTests;

namespace Hms.UnitTests;

/// <summary>Sprint 2.2/2.3 endpoint guards through the real pipeline (EF InMemory; DB RPCs faked as P0002).</summary>
public sealed class AppointmentsInProcessTests(ApiFactory factory) : IClassFixture<ApiFactory>
{
    private sealed record Practitioner(Guid Id, string DisplayName, bool IsActive);

    private sealed record Appointment(Guid Id, string Status, DateTimeOffset StartsAt, DateTimeOffset EndsAt);

    private static readonly DateTimeOffset Slot = new(2031, 3, 3, 10, 0, 0, TimeSpan.FromHours(5.5));

    private static async Task<string?> CodeOf(HttpResponseMessage response)
    {
        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        return doc.RootElement.TryGetProperty("code", out var code) ? code.GetString() : null;
    }

    private async Task<Practitioner> CreatePractitionerAsync()
    {
        using var admin = factory.ClientAs(Admin);
        var response = await admin.PostAsJsonAsync("/api/v1/practitioners", new { displayName = "Dr. Synthetic", specialty = "GP" });
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        return (await response.Content.ReadFromJsonAsync<Practitioner>())!;
    }

    private static Task<HttpResponseMessage> BookAsync(HttpClient client, Guid branch, Guid practitioner, DateTimeOffset start, int minutes = 15) =>
        client.PostAsJsonAsync("/api/v1/appointments", new
        {
            branchId = branch, practitionerId = practitioner, patientId = Guid.NewGuid(), startsAt = start, endsAt = start.AddMinutes(minutes),
        });

    [Fact]
    public async Task Practitioners_are_admin_managed_and_validated()
    {
        using var nurse = factory.ClientAs(MixedUser);
        Assert.Equal(HttpStatusCode.Forbidden, (await nurse.PostAsJsonAsync("/api/v1/practitioners", new { displayName = "X" })).StatusCode);
        using var admin = factory.ClientAs(Admin);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PostAsJsonAsync("/api/v1/practitioners", new { displayName = "  " })).StatusCode);

        var pr = await CreatePractitionerAsync();
        Assert.True(pr.IsActive);
        Assert.Equal(HttpStatusCode.Forbidden, (await nurse.PatchAsJsonAsync($"/api/v1/practitioners/{pr.Id}", new { isActive = false })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PatchAsJsonAsync($"/api/v1/practitioners/{Guid.NewGuid()}", new { isActive = false })).StatusCode);
    }

    [Fact]
    public async Task Schedules_validate_times_and_bind_to_branch()
    {
        var pr = await CreatePractitionerAsync();
        using var admin = factory.ClientAs(Admin);
        var inverted = await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = pr.Id, branchId = Main, weekday = 1, startTime = "12:00", endTime = "09:00" });
        Assert.Equal(HttpStatusCode.BadRequest, inverted.StatusCode);

        using var nurse = factory.ClientAs(MixedUser);
        Assert.Equal(HttpStatusCode.Forbidden, (await nurse.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = pr.Id, branchId = East, weekday = 1, startTime = "09:00", endTime = "12:00" })).StatusCode);
        // contract v4: another tenant's branch is 404, never 403
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = pr.Id, branchId = BetaMain, weekday = 1, startTime = "09:00", endTime = "12:00" })).StatusCode);
        Assert.Equal(HttpStatusCode.Created, (await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = pr.Id, branchId = Main, weekday = 1, startTime = "09:00", endTime = "12:00" })).StatusCode);
    }

    [Fact]
    public async Task Booking_checks_role_branch_times_and_overlap()
    {
        var pr = await CreatePractitionerAsync();
        using var admin = factory.ClientAs(Admin);
        using var lab = factory.ClientAs(LabTech);

        Assert.Equal(HttpStatusCode.Forbidden, (await BookAsync(lab, Main, pr.Id, Slot)).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await BookAsync(admin, BetaMain, pr.Id, Slot)).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await BookAsync(admin, Main, pr.Id, Slot, minutes: 0)).StatusCode);

        var first = await BookAsync(admin, Main, pr.Id, Slot, 30);
        Assert.Equal(HttpStatusCode.Created, first.StatusCode);
        var booked = (await first.Content.ReadFromJsonAsync<Appointment>())!;
        Assert.Equal("booked", booked.Status);

        var overlap = await BookAsync(admin, Main, pr.Id, Slot.AddMinutes(15));
        Assert.Equal(HttpStatusCode.Conflict, overlap.StatusCode);
        Assert.Equal("appointment_overlap", await CodeOf(overlap));
        Assert.Equal(HttpStatusCode.Created, (await BookAsync(admin, Main, pr.Id, Slot.AddMinutes(30))).StatusCode); // back-to-back

        var cancel = await admin.PostAsJsonAsync($"/api/v1/appointments/{booked.Id}/cancel", new { reason = "patient request" });
        Assert.Equal(HttpStatusCode.OK, cancel.StatusCode);
        Assert.Equal("cancelled", (await cancel.Content.ReadFromJsonAsync<Appointment>())!.Status);
        Assert.Equal(HttpStatusCode.Created, (await BookAsync(admin, Main, pr.Id, Slot.AddMinutes(10))).StatusCode);

        var again = await admin.PostAsJsonAsync($"/api/v1/appointments/{booked.Id}/cancel", new { reason = "twice" });
        Assert.Equal(HttpStatusCode.Conflict, again.StatusCode);
    }

    [Fact]
    public async Task Slots_and_queue_validate_and_scope_branches()
    {
        using var admin = factory.ClientAs(Admin);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.GetAsync($"/api/v1/slots?branchId={Main}&from=2031-03-01&to=2031-05-01")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.GetAsync($"/api/v1/slots?branchId={Main}&from=2031-03-01")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.GetAsync($"/api/v1/slots?branchId={BetaMain}&from=2031-03-01")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.GetAsync($"/api/v1/queue?branchId={BetaMain}")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.GetAsync($"/api/v1/queue?branchId={Main}")).StatusCode);

        using var lab = factory.ClientAs(LabTech);
        Assert.Equal(HttpStatusCode.Forbidden, (await lab.GetAsync($"/api/v1/queue?branchId={Main}")).StatusCode);

        var badStatus = await admin.PatchAsJsonAsync($"/api/v1/queue/{Guid.NewGuid()}", new { status = "waiting" });
        Assert.Equal(HttpStatusCode.BadRequest, badStatus.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PatchAsJsonAsync($"/api/v1/queue/{Guid.NewGuid()}", new { status = "done" })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PostAsJsonAsync("/api/v1/queue/walk-in", new { branchId = BetaMain, patientId = Guid.NewGuid() })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PostAsJsonAsync("/api/v1/queue/walk-in", new { branchId = Main, patientId = Guid.NewGuid() })).StatusCode); // RPC P0002
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PostAsync($"/api/v1/appointments/{Guid.NewGuid()}/check-in", null)).StatusCode);

        Assert.Equal(HttpStatusCode.OK, (await admin.GetAsync($"/api/v1/slots?branchId={Main}&date=2031-03-01")).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.GetAsync($"/api/v1/slots?branchId={Main}&date=2031-03-01&from=2031-03-01")).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.GetAsync($"/api/v1/slots?branchId={Main}&date=not-a-date")).StatusCode);

        Assert.Equal(HttpStatusCode.Forbidden, (await lab.PostAsJsonAsync("/api/v1/queue/close-day", new { branchId = Main })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PostAsJsonAsync("/api/v1/queue/close-day", new { branchId = Main, date = "2099-01-01" })).StatusCode);
        var ended = await admin.PostAsJsonAsync("/api/v1/queue/close-day", new { branchId = Main, date = "2026-10-06" });
        Assert.Equal(HttpStatusCode.OK, ended.StatusCode);
        Assert.Equal(2, (await ended.Content.ReadFromJsonAsync<CloseQueueDay>())!.ExpiredCount);
    }

    [Fact]
    public async Task Closing_today_before_it_ends_needs_an_admin_and_a_reason()
    {
        // Now = 2026-10-07 01:30 at Main (Asia/Kolkata): "today" there has not ended yet (#142, QUE-007).
        using var admin = factory.ClientAs(Admin);
        using var reception = factory.ClientAs(RoleUsers[HmsRoles.Receptionist]);

        var noReason = await reception.PostAsJsonAsync("/api/v1/queue/close-day", new { branchId = Main });
        Assert.Equal(HttpStatusCode.BadRequest, noReason.StatusCode);
        Assert.Contains("cannot be closed before it ends in the branch time zone", await noReason.Content.ReadAsStringAsync(), StringComparison.Ordinal);

        var adminNoReason = await admin.PostAsJsonAsync("/api/v1/queue/close-day", new { branchId = Main, date = "2026-10-07" });
        Assert.Equal(HttpStatusCode.BadRequest, adminNoReason.StatusCode);

        var blank = await admin.PostAsJsonAsync("/api/v1/queue/close-day", new { branchId = Main, reason = "   " });
        Assert.Equal(HttpStatusCode.BadRequest, blank.StatusCode);

        var tooShort = await admin.PostAsJsonAsync("/api/v1/queue/close-day", new { branchId = Main, reason = "no" });
        Assert.Equal(HttpStatusCode.BadRequest, tooShort.StatusCode);
        Assert.Contains("reason", await tooShort.Content.ReadAsStringAsync(), StringComparison.OrdinalIgnoreCase);

        var tooLong = await admin.PostAsJsonAsync("/api/v1/queue/close-day", new { branchId = Main, reason = new string('x', 501) });
        Assert.Equal(HttpStatusCode.BadRequest, tooLong.StatusCode);

        var receptionWithReason = await reception.PostAsJsonAsync("/api/v1/queue/close-day", new { branchId = Main, reason = "Zz-QA power cut" });
        Assert.Equal(HttpStatusCode.Forbidden, receptionWithReason.StatusCode);

        var future = await admin.PostAsJsonAsync("/api/v1/queue/close-day", new { branchId = Main, date = "2026-10-08", reason = "Zz-QA future" });
        Assert.Equal(HttpStatusCode.BadRequest, future.StatusCode);

        var early = await admin.PostAsJsonAsync("/api/v1/queue/close-day", new { branchId = Main, reason = "Zz-QA emergency closure" });
        Assert.Equal(HttpStatusCode.OK, early.StatusCode);
        var result = (await early.Content.ReadFromJsonAsync<CloseQueueDay>())!;
        Assert.Equal(new DateOnly(2026, 10, 7), result.QueueDate);

        var receptionEnded = await reception.PostAsJsonAsync("/api/v1/queue/close-day", new { branchId = Main, date = "2026-10-06" });
        Assert.Equal(HttpStatusCode.OK, receptionEnded.StatusCode);
    }

    private sealed record CloseQueueDay(Guid BranchId, DateOnly QueueDate, int ExpiredCount);

    [Fact]
    public async Task Booking_outside_working_hours_requires_a_reason()
    {
        var pr = await CreatePractitionerAsync();
        using var admin = factory.ClientAs(Admin);
        var missing = await admin.PostAsJsonAsync("/api/v1/appointments", new
        {
            branchId = Main, practitionerId = pr.Id, patientId = Guid.NewGuid(), startsAt = Slot, endsAt = Slot.AddMinutes(15), overrideWorkingHours = true,
        });
        Assert.Equal(HttpStatusCode.BadRequest, missing.StatusCode);
        Assert.Contains("reason", await missing.Content.ReadAsStringAsync(), StringComparison.OrdinalIgnoreCase);

        var blank = await admin.PostAsJsonAsync("/api/v1/appointments", new
        {
            branchId = Main, practitionerId = pr.Id, patientId = Guid.NewGuid(), startsAt = Slot, endsAt = Slot.AddMinutes(15),
            overrideWorkingHours = true, reason = "   ",
        });
        Assert.Equal(HttpStatusCode.BadRequest, blank.StatusCode);

        var booked = await admin.PostAsJsonAsync("/api/v1/appointments", new
        {
            branchId = Main, practitionerId = pr.Id, patientId = Guid.NewGuid(), startsAt = Slot, endsAt = Slot.AddMinutes(15),
            overrideWorkingHours = true, reason = "Emergency add-on (synthetic)",
        });
        Assert.Equal(HttpStatusCode.Created, booked.StatusCode);
    }

    [Fact]
    public async Task No_show_before_the_start_is_a_friendly_conflict()
    {
        var pr = await CreatePractitionerAsync();
        using var admin = factory.ClientAs(Admin);
        var booked = await BookAsync(admin, Main, pr.Id, Slot);
        Assert.Equal(HttpStatusCode.Created, booked.StatusCode);
        var id = (await booked.Content.ReadFromJsonAsync<Appointment>())!.Id;

        var noShow = await admin.PostAsync($"/api/v1/appointments/{id}/no-show", null);
        Assert.Equal(HttpStatusCode.Conflict, noShow.StatusCode);
        Assert.Equal("invalid_transition", await CodeOf(noShow));
        var detail = await noShow.Content.ReadAsStringAsync();
        Assert.Contains("Only booked appointments that have started can be marked as no-show.", detail, StringComparison.Ordinal);
        Assert.DoesNotContain("invalid_transition:", detail, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_doctor_lists_only_appointments_of_their_linked_practitioner()
    {
        var doctorId = RoleUsers["doctor"];
        using var admin = factory.ClientAs(Admin);
        var own = await CreatePractitionerAsync();
        var other = await CreatePractitionerAsync();
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync($"/api/v1/practitioners/{own.Id}", new { userId = doctorId })).StatusCode);

        Assert.Equal(HttpStatusCode.Created, (await BookAsync(admin, Main, own.Id, Slot.AddDays(1))).StatusCode);
        var hidden = await BookAsync(admin, Main, other.Id, Slot.AddDays(1).AddHours(1));
        Assert.Equal(HttpStatusCode.Created, hidden.StatusCode);
        var hiddenId = (await hidden.Content.ReadFromJsonAsync<Appointment>())!.Id;

        using var doctor = factory.ClientAs(doctorId);
        var list = await doctor.GetAsync($"/api/v1/appointments?branchId={Main}");
        Assert.Equal(HttpStatusCode.OK, list.StatusCode);
        using var doc = JsonDocument.Parse(await list.Content.ReadAsStringAsync());
        Assert.Equal(1, doc.RootElement.GetProperty("items").GetArrayLength());
        Assert.Equal(HttpStatusCode.NotFound, (await doctor.GetAsync($"/api/v1/appointments/{hiddenId}")).StatusCode);
    }
}
