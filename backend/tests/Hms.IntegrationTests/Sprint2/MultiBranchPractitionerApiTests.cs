using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2;

/// <summary>One doctor, two branches, different hours. Booking follows the branch being booked.</summary>
[Trait("Category", "Database")]
public sealed class MultiBranchPractitionerApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly DateOnly Day = TestDates.FarMonday(weeks: 26);
    private static DateTimeOffset At(int hour, int minute = 0) => TestDates.At(Day, hour, minute);

    [Fact]
    public async Task A_doctor_is_bookable_only_at_the_branch_and_hours_they_work()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var pr = await S2.CreatePractitionerAsync(admin);
        var patient = await S2.CreatePatientAsync(admin, AlphaMain);
        var morning = new { practitionerId = pr.Id, branchId = AlphaMain, weekday = 1, startTime = "09:00", endTime = "13:00", slotMinutes = 30, validFrom = "2026-01-01" };
        var evening = new { practitionerId = pr.Id, branchId = AlphaEast, weekday = 1, startTime = "17:00", endTime = "20:00", slotMinutes = 30, validFrom = "2026-01-01" };
        Assert.Equal(HttpStatusCode.Created, (await admin.PostAsJsonAsync("/api/v1/schedules", morning)).StatusCode);
        Assert.Equal(HttpStatusCode.Created, (await admin.PostAsJsonAsync("/api/v1/schedules", evening)).StatusCode);

        var atMain = await admin.GetFromJsonAsync<List<S2Practitioner>>($"/api/v1/practitioners?branchId={AlphaMain}");
        var atEast = await admin.GetFromJsonAsync<List<S2Practitioner>>($"/api/v1/practitioners?branchId={AlphaEast}");
        Assert.Contains(atMain!, p => p.Id == pr.Id);
        Assert.Contains(atEast!, p => p.Id == pr.Id);

        var mainSlots = await admin.GetFromJsonAsync<List<S2Slot>>($"/api/v1/slots?branchId={AlphaMain}&from={TestDates.Iso(Day)}&to={TestDates.Iso(Day)}&practitionerId={pr.Id}");
        var eastSlots = await admin.GetFromJsonAsync<List<S2Slot>>($"/api/v1/slots?branchId={AlphaEast}&from={TestDates.Iso(Day)}&to={TestDates.Iso(Day)}&practitionerId={pr.Id}");
        Assert.NotEmpty(mainSlots!);
        Assert.NotEmpty(eastSlots!);
        Assert.All(mainSlots!, s => Assert.InRange(s.StartsAt.ToOffset(Ist).Hour, 9, 12));
        Assert.All(eastSlots!, s => Assert.InRange(s.StartsAt.ToOffset(Ist).Hour, 17, 19));
        Assert.DoesNotContain(mainSlots!, s => s.StartsAt.ToOffset(Ist).Hour >= 17);
        Assert.DoesNotContain(eastSlots!, s => s.StartsAt.ToOffset(Ist).Hour < 17);

        Assert.Equal(HttpStatusCode.Created, (await BookAsync(admin, AlphaMain, pr.Id, patient.Id, At(9))).StatusCode);
        Assert.Equal(HttpStatusCode.Created, (await BookAsync(admin, AlphaEast, pr.Id, patient.Id, At(17))).StatusCode);

        var outside = await BookAsync(admin, AlphaEast, pr.Id, patient.Id, At(10));
        Assert.Equal(HttpStatusCode.BadRequest, outside.StatusCode);
        Assert.Contains("outside_working_hours", await outside.Content.ReadAsStringAsync(), StringComparison.Ordinal);

        var duringMain = await BookAsync(admin, AlphaEast, pr.Id, patient.Id, At(12), overrideHours: true);
        Assert.Equal(HttpStatusCode.Conflict, duringMain.StatusCode);
        Assert.Equal("appointment_overlap", await S2.CodeAsync(duringMain));

        var memberships = await admin.GetFromJsonAsync<List<BranchMembership>>($"/api/v1/practitioner-branches?practitionerId={pr.Id}");
        var east = memberships!.Single(m => m.BranchId == AlphaEast);
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync($"/api/v1/practitioner-branches/{east.Id}", new { isActive = false })).StatusCode);
        var after = await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = pr.Id, branchId = AlphaEast, weekday = 5, startTime = "17:00", endTime = "18:00", validFrom = "2026-01-01" });
        Assert.Equal(HttpStatusCode.BadRequest, after.StatusCode);
        Assert.Contains("practitioner_not_at_branch", await after.Content.ReadAsStringAsync(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task My_day_lists_every_branch_for_the_linked_doctor()
    {
        using var doctor = factory.ClientAs(BetaDoctor, Beta);
        var day = await doctor.GetFromJsonAsync<MyDay>("/api/v1/practitioners/me/day?date=2030-01-07");
        Assert.Equal(Guid.Parse("c2222222-0000-4000-8000-000000000001"), day!.PractitionerId);
        Assert.Contains(day.Items, i => i.Kind == "hours" && i.BranchId == BetaMain);
        Assert.Contains(day.Items, i => i.Kind == "appointment" && i.BranchId == BetaMain && i.Patient != null);

        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var empty = await admin.GetFromJsonAsync<MyDay>("/api/v1/practitioners/me/day?date=2030-01-07");
        Assert.Null(empty!.PractitionerId);
        Assert.Empty(empty.Items);
    }

    private static Task<HttpResponseMessage> BookAsync(HttpClient client, Guid branch, Guid practitioner, Guid patient, DateTimeOffset start, bool overrideHours = false) =>
        client.PostAsJsonAsync("/api/v1/appointments", new
        {
            branchId = branch,
            practitionerId = practitioner,
            patientId = patient,
            startsAt = start,
            endsAt = start.AddMinutes(15),
            reason = "Synthetic multi-branch visit",
            overrideWorkingHours = overrideHours ? true : (bool?)null,
        });

    private sealed record BranchMembership(Guid Id, Guid PractitionerId, Guid BranchId, bool IsActive);

    private sealed record MyDay(Guid? PractitionerId, string? DisplayName, DateOnly Date, List<MyDayItem> Items);

    private sealed record MyDayItem(string Kind, Guid BranchId, DateTimeOffset StartsAt, DateTimeOffset EndsAt, Guid? AppointmentId, string? Status, S2PatientRef? Patient);
}
