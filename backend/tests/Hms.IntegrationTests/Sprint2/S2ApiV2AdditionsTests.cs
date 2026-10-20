using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2;

/// <summary>API v2 additions: embedded patient on appointment/queue responses; GET /practitioners?branchId=.</summary>
[Trait("Category", "Database")]
public sealed class S2ApiV2AdditionsTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static void AssertPatient(S2Patient expected, S2PatientRef? actual)
    {
        Assert.NotNull(actual);
        Assert.Equal(expected.Id, actual.Id);
        Assert.Equal(expected.Mrn, actual.Mrn);
        Assert.Equal(expected.FirstName, actual.FirstName);
        Assert.Equal(expected.LastName, actual.LastName);
    }

    [Fact]
    public async Task Appointment_and_queue_responses_embed_the_patient_for_readers()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var billingUser = await CreateUserAsync("s2-v2-billing", (Alpha, AlphaEast, "billing"));
        var receptionUser = await CreateUserAsync("s2-v2-reception", (Alpha, AlphaEast, "receptionist"));
        using var billing = factory.ClientAs(billingUser, Alpha);
        using var reception = factory.ClientAs(receptionUser, Alpha);
        var pr = await S2.CreatePractitionerAsync(admin);
        var patient = await S2.CreatePatientAsync(admin, AlphaEast);

        // create (201) embeds it
        var booked = await S2.BookAsync(admin, AlphaEast, pr.Id, patient.Id, S2.TodayAt(13), 20);
        Assert.Equal(HttpStatusCode.Created, booked.StatusCode);
        var appt = (await booked.Content.ReadFromJsonAsync<S2Appointment>())!;
        AssertPatient(patient, appt.Patient);
        var other = (await (await S2.BookAsync(admin, AlphaEast, pr.Id, (await S2.CreatePatientAsync(admin, AlphaEast)).Id, S2.TodayAt(14), 20))
            .Content.ReadFromJsonAsync<S2Appointment>())!;

        // list + detail, also for a read-only role (billing)
        var page = await billing.GetFromJsonAsync<S2Page<S2Appointment>>($"/api/v1/appointments?practitionerId={pr.Id}");
        Assert.Equal(2, page!.Items.Count);
        AssertPatient(patient, page.Items.Single(a => a.Id == appt.Id).Patient);
        Assert.NotEqual(patient.Id, page.Items.Single(a => a.Id == other.Id).Patient!.Id); // per row, not the first one
        AssertPatient(patient, (await billing.GetFromJsonAsync<S2Appointment>($"/api/v1/appointments/{appt.Id}"))!.Patient);

        // check-in result, queue board and queue PATCH
        var checkIn = await reception.PostAsync($"/api/v1/appointments/{appt.Id}/check-in", null);
        Assert.Equal(HttpStatusCode.Created, checkIn.StatusCode);
        var result = (await checkIn.Content.ReadFromJsonAsync<S2CheckIn>())!;
        AssertPatient(patient, result.Entry.Patient);
        var board = (await reception.GetFromJsonAsync<List<S2QueueEntry>>  /* RBAC: billing has no queue access */($"/api/v1/queue?branchId={AlphaEast}"))!;
        AssertPatient(patient, board.Single(q => q.Id == result.QueueEntryId).Patient);
        Assert.All(board, q => Assert.Equal(q.PatientId, q.Patient!.Id));
        var patched = await reception.PatchAsJsonAsync($"/api/v1/queue/{result.QueueEntryId}", new { status = "cancelled" });
        Assert.Equal(HttpStatusCode.OK, patched.StatusCode);
        AssertPatient(patient, (await patched.Content.ReadFromJsonAsync<S2QueueEntry>())!.Patient);

        // a mutation response (cancel) embeds it too
        var cancelled = await admin.PostAsJsonAsync($"/api/v1/appointments/{other.Id}/cancel", new { reason = "test" });
        Assert.Equal(other.PatientId, (await cancelled.Content.ReadFromJsonAsync<S2Appointment>())!.Patient!.Id);
    }

    [Fact]
    public async Task Soft_deleted_patient_is_not_embedded_and_other_tenants_never_see_the_row()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        var pr = await S2.CreatePractitionerAsync(admin);
        var patient = await S2.CreatePatientAsync(admin, AlphaMain);
        var appt = (await (await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, S2.FutureSlot(9, 11))).Content.ReadFromJsonAsync<S2Appointment>())!;
        Assert.Equal(HttpStatusCode.OK, (await admin.PostAsJsonAsync($"/api/v1/appointments/{appt.Id}/cancel", new { })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync($"/api/v1/patients/{patient.Id}")).StatusCode);

        // same visibility as GET /patients/{id}: deleted -> null (the appointment row itself stays readable)
        var read = (await admin.GetFromJsonAsync<S2Appointment>($"/api/v1/appointments/{appt.Id}"))!;
        Assert.Equal(patient.Id, read.PatientId);
        Assert.Null(read.Patient);
        var listed = (await admin.GetFromJsonAsync<S2Page<S2Appointment>>($"/api/v1/appointments?practitionerId={pr.Id}"))!;
        Assert.Null(Assert.Single(listed.Items).Patient);

        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync($"/api/v1/appointments/{appt.Id}")).StatusCode);
        Assert.DoesNotContain((await beta.GetFromJsonAsync<S2Page<S2Appointment>>("/api/v1/appointments?pageSize=100"))!.Items,
            a => a.Patient?.Mrn == patient.Mrn);
    }

    [Fact]
    public async Task Practitioners_can_be_filtered_by_an_active_schedule_at_a_branch()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var receptionMainUser = await CreateUserAsync("s2-v2-rmain", (Alpha, AlphaMain, "receptionist"));
        using var receptionMain = factory.ClientAs(receptionMainUser, Alpha);
        using var beta = factory.ClientAs(BetaAdmin, Beta);

        var atEast = await S2.CreatePractitionerAsync(admin);
        var atMain = await S2.CreatePractitionerAsync(admin);
        var inactiveSchedule = await S2.CreatePractitionerAsync(admin);
        var endedSchedule = await S2.CreatePractitionerAsync(admin);
        var futureSchedule = await S2.CreatePractitionerAsync(admin);
        var none = await S2.CreatePractitionerAsync(admin);

        async Task<S2Schedule> Schedule(Guid practitioner, Guid branch, object? extra = null)
        {
            var body = new Dictionary<string, object?>
            {
                ["practitionerId"] = practitioner, ["branchId"] = branch, ["weekday"] = 6, ["startTime"] = "09:00", ["endTime"] = "10:00",
            };
            foreach (var p in extra?.GetType().GetProperties() ?? [])
            {
                body[p.Name] = p.GetValue(extra);
            }

            var response = await admin.PostAsJsonAsync("/api/v1/schedules", body);
            Assert.Equal(HttpStatusCode.Created, response.StatusCode);
            return (await response.Content.ReadFromJsonAsync<S2Schedule>())!;
        }

        await Schedule(atEast.Id, AlphaEast);
        await Schedule(atMain.Id, AlphaMain);
        var off = await Schedule(inactiveSchedule.Id, AlphaEast);
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync($"/api/v1/schedules/{off.Id}", new { isActive = false })).StatusCode);
        await Schedule(endedSchedule.Id, AlphaEast, new { validFrom = "2020-01-01", validTo = "2020-12-31" });
        await Schedule(futureSchedule.Id, AlphaEast, new { validFrom = "2031-01-01" });
        _ = none;

        var mine = new HashSet<Guid> { atEast.Id, atMain.Id, inactiveSchedule.Id, endedSchedule.Id, futureSchedule.Id, none.Id };
        async Task<HashSet<Guid>> List(HttpClient client, string query) =>
            [.. (await client.GetFromJsonAsync<List<S2Practitioner>>($"/api/v1/practitioners{query}"))!.Select(p => p.Id).Where(mine.Contains)];

        Assert.Equal(mine, await List(admin, ""));                                                   // unfiltered: unchanged
        Assert.Equal([atEast.Id, futureSchedule.Id], await List(admin, $"?branchId={AlphaEast}"));
        Assert.Equal([atMain.Id], await List(admin, $"?branchId={AlphaMain}"));
        // any tenant member may list (schedules are tenant-wide), even for a branch outside their scope
        Assert.Equal([atEast.Id, futureSchedule.Id], await List(receptionMain, $"?branchId={AlphaEast}"));

        // deactivated practitioner drops out with activeOnly (default) but not with activeOnly=false
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync($"/api/v1/practitioners/{atEast.Id}", new { isActive = false })).StatusCode);
        Assert.Equal([futureSchedule.Id], await List(admin, $"?branchId={AlphaEast}"));
        Assert.Equal([atEast.Id, futureSchedule.Id], await List(admin, $"?branchId={AlphaEast}&activeOnly=false"));

        // v4: another tenant's branch is 404
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync($"/api/v1/practitioners?branchId={AlphaEast}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.GetAsync($"/api/v1/practitioners?branchId={BetaMain}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.GetAsync($"/api/v1/practitioners?branchId={Guid.NewGuid()}")).StatusCode);
    }
}
