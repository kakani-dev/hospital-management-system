using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Hms.SharedKernel.Tenancy;
using static Hms.UnitTests.InProcessApiTests;

namespace Hms.UnitTests;

/// <summary>
/// Visit-type snapshots and NMC fields through the real pipeline (EF InMemory).
/// The unique registration index and RLS are in supabase/tests/45_visit_types_and_nmc_test.sql.
/// </summary>
public sealed class VisitTypesNmcInProcessTests(ApiFactory factory) : IClassFixture<ApiFactory>
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private HttpClient AsAdmin() => factory.ClientAs(InProcessApiTests.Admin);

    private async Task<Guid> PractitionerAsync(object body)
    {
        using var admin = AsAdmin();
        var response = await admin.PostAsJsonAsync("/api/v1/practitioners", body);
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        return (await response.Content.ReadFromJsonAsync<JsonElement>(Json)).GetProperty("id").GetGuid();
    }

    private Task<Guid> PractitionerAsync(string name) =>
        PractitionerAsync(new { displayName = name });

    private static async Task<JsonElement> CreateTypeAsync(HttpClient admin, string code, int fee, int minutes, int? window, long? followFee)
    {
        var response = await admin.PostAsJsonAsync("/api/v1/visit-types", new
        {
            code, name = code, defaultFeePaise = fee, durationMinutes = minutes, followUpValidDays = window, followUpFeePaise = followFee,
        });
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        return await response.Content.ReadFromJsonAsync<JsonElement>(Json);
    }

    private static async Task<Guid> FollowUpIdAsync(HttpClient admin)
    {
        var response = await admin.GetAsync($"/api/v1/visit-types?branchId={Main}");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var rows = await response.Content.ReadFromJsonAsync<List<JsonElement>>(Json);
        return rows!.Single(r => r.GetProperty("code").GetString() == "follow_up").GetProperty("id").GetGuid();
    }

    private static async Task<JsonElement> BookAsync(HttpClient admin, Guid branch, Guid doctor, Guid patient, DateTimeOffset start, Guid? visitTypeId, int clientMinutes = 5)
    {
        var response = await admin.PostAsJsonAsync("/api/v1/appointments", new
        {
            branchId = branch, practitionerId = doctor, patientId = patient, startsAt = start, endsAt = start.AddMinutes(clientMinutes), visitTypeId,
        });
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        return await response.Content.ReadFromJsonAsync<JsonElement>(Json);
    }

    private static async Task<JsonElement> SuggestAsync(HttpClient admin, Guid branch, Guid doctor, Guid patient, DateTimeOffset start)
    {
        var response = await admin.GetAsync(
            $"/api/v1/visit-types/suggestion?branchId={branch}&practitionerId={doctor}&patientId={patient}&startsAt={Uri.EscapeDataString(start.ToString("o"))}");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await response.Content.ReadFromJsonAsync<JsonElement>(Json);
    }

    private static async Task<JsonElement> GetAppointmentAsync(HttpClient admin, Guid id)
    {
        var response = await admin.GetAsync($"/api/v1/appointments/{id}");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await response.Content.ReadFromJsonAsync<JsonElement>(Json);
    }

    [Fact]
    public async Task Editing_a_visit_type_does_not_change_an_existing_booking()
    {
        using var admin = AsAdmin();
        var type = await CreateTypeAsync(admin, "editfee" + Guid.NewGuid().ToString("N")[..6], 50_000, 30, 7, 0);
        var id = type.GetProperty("id").GetGuid();
        var doctor = await PractitionerAsync("Dr. Edit");
        var start = new DateTimeOffset(2026, 9, 1, 4, 0, 0, TimeSpan.Zero);
        var booked = await BookAsync(admin, Main, doctor, Guid.NewGuid(), start, id);
        Assert.Equal(50_000, booked.GetProperty("consultationFeePaise").GetInt64());
        Assert.Equal(start.AddMinutes(30), booked.GetProperty("endsAt").GetDateTimeOffset());

        var patch = await admin.PatchAsJsonAsync($"/api/v1/visit-types/{id}", new { defaultFeePaise = 90_000, durationMinutes = 45, followUpFeePaise = 15_000, followUpValidDays = 2 });
        Assert.Equal(HttpStatusCode.OK, patch.StatusCode);
        var again = await GetAppointmentAsync(admin, booked.GetProperty("id").GetGuid());
        Assert.Equal(50_000, again.GetProperty("consultationFeePaise").GetInt64());
        Assert.Equal(start.AddMinutes(30), again.GetProperty("endsAt").GetDateTimeOffset());

        var next = await BookAsync(admin, Main, doctor, Guid.NewGuid(), start.AddHours(2), id);
        Assert.Equal(90_000, next.GetProperty("consultationFeePaise").GetInt64());
        Assert.Equal(start.AddHours(2).AddMinutes(45), next.GetProperty("endsAt").GetDateTimeOffset());
    }

    [Fact]
    public async Task Deactivated_visit_type_blocks_new_bookings_and_keeps_the_old_one()
    {
        using var admin = AsAdmin();
        var type = await CreateTypeAsync(admin, "gone" + Guid.NewGuid().ToString("N")[..6], 40_000, 20, 7, 0);
        var id = type.GetProperty("id").GetGuid();
        var doctor = await PractitionerAsync("Dr. Gone");
        var start = new DateTimeOffset(2026, 9, 2, 4, 0, 0, TimeSpan.Zero);
        var booked = await BookAsync(admin, Main, doctor, Guid.NewGuid(), start, id);
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync($"/api/v1/visit-types/{id}", new { isActive = false })).StatusCode);

        var stale = await admin.PostAsJsonAsync("/api/v1/appointments", new
        {
            branchId = Main, practitionerId = doctor, patientId = Guid.NewGuid(), startsAt = start.AddHours(3), endsAt = start.AddHours(3).AddMinutes(5), visitTypeId = id,
        });
        Assert.Equal(HttpStatusCode.BadRequest, stale.StatusCode);
        Assert.Contains("visitTypeId", await stale.Content.ReadAsStringAsync(), StringComparison.Ordinal);

        var kept = await GetAppointmentAsync(admin, booked.GetProperty("id").GetGuid());
        Assert.Equal(id, kept.GetProperty("visitTypeId").GetGuid());
        Assert.Equal(40_000, kept.GetProperty("consultationFeePaise").GetInt64());
    }

    [Fact]
    public async Task Follow_up_window_does_not_follow_a_different_doctor()
    {
        using var admin = AsAdmin();
        var type = await CreateTypeAsync(admin, "doc" + Guid.NewGuid().ToString("N")[..6], 50_000, 30, 7, 0);
        var first = await PractitionerAsync("Dr. One");
        var other = await PractitionerAsync("Dr. Two");
        var patient = Guid.NewGuid();
        await FollowUpIdAsync(admin);
        var prior = await BookAsync(admin, Main, first, patient, new DateTimeOffset(2026, 10, 1, 4, 0, 0, TimeSpan.Zero), type.GetProperty("id").GetGuid());
        var suggestion = await SuggestAsync(admin, Main, other, patient, new DateTimeOffset(2026, 10, 4, 4, 0, 0, TimeSpan.Zero));
        Assert.False(suggestion.GetProperty("suggested").GetBoolean());
        Assert.Equal("new_consult", suggestion.GetProperty("code").GetString());
        Assert.Equal(JsonValueKind.Null, suggestion.GetProperty("priorAppointmentId").ValueKind);
        Assert.NotEqual(Guid.Empty, prior.GetProperty("id").GetGuid());
    }

    [Fact]
    public async Task Branch_change_keeps_the_snapshotted_follow_up_fee()
    {
        using var admin = AsAdmin();
        var type = await CreateTypeAsync(admin, "br" + Guid.NewGuid().ToString("N")[..6], 50_000, 30, 7, 0);
        var typeId = type.GetProperty("id").GetGuid();
        var followUp = await FollowUpIdAsync(admin);
        var doctor = await PractitionerAsync("Dr. Branch");
        var patient = Guid.NewGuid();
        var prior = await BookAsync(admin, Main, doctor, patient, new DateTimeOffset(2026, 10, 1, 4, 0, 0, TimeSpan.Zero), typeId);
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync($"/api/v1/visit-types/{typeId}", new { followUpFeePaise = 15_000 })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.PostAsJsonAsync($"/api/v1/visit-types/{followUp}/overrides", new { branchId = East, feePaise = 77_000 })).StatusCode);

        var when = new DateTimeOffset(2026, 10, 4, 4, 0, 0, TimeSpan.Zero);
        var suggestion = await SuggestAsync(admin, East, doctor, patient, when);
        Assert.True(suggestion.GetProperty("suggested").GetBoolean());
        Assert.Equal(0, suggestion.GetProperty("feePaise").GetInt64());
        Assert.Equal(prior.GetProperty("id").GetGuid(), suggestion.GetProperty("priorAppointmentId").GetGuid());

        var booked = await BookAsync(admin, East, doctor, patient, when, suggestion.GetProperty("visitTypeId").GetGuid());
        Assert.Equal(0, booked.GetProperty("consultationFeePaise").GetInt64());
    }

    [Fact]
    public async Task Cancelled_previous_visit_does_not_count_and_the_older_one_does()
    {
        using var admin = AsAdmin();
        var type = await CreateTypeAsync(admin, "can" + Guid.NewGuid().ToString("N")[..6], 50_000, 30, 7, 0);
        var typeId = type.GetProperty("id").GetGuid();
        await FollowUpIdAsync(admin);
        var doctor = await PractitionerAsync("Dr. Cancel");
        var patient = Guid.NewGuid();
        var older = await BookAsync(admin, Main, doctor, patient, new DateTimeOffset(2026, 10, 1, 4, 0, 0, TimeSpan.Zero), typeId);
        var later = await BookAsync(admin, Main, doctor, patient, new DateTimeOffset(2026, 10, 3, 4, 0, 0, TimeSpan.Zero), typeId);
        var cancel = await admin.PostAsJsonAsync($"/api/v1/appointments/{later.GetProperty("id").GetGuid()}/cancel", new { reason = "synthetic" });
        Assert.Equal(HttpStatusCode.OK, cancel.StatusCode);

        var suggestion = await SuggestAsync(admin, Main, doctor, patient, new DateTimeOffset(2026, 10, 6, 4, 0, 0, TimeSpan.Zero));
        Assert.True(suggestion.GetProperty("suggested").GetBoolean());
        Assert.Equal(older.GetProperty("id").GetGuid(), suggestion.GetProperty("priorAppointmentId").GetGuid());
    }

    [Fact]
    public async Task No_show_previous_visit_does_not_count_and_the_older_one_does()
    {
        using var admin = AsAdmin();
        var type = await CreateTypeAsync(admin, "ns" + Guid.NewGuid().ToString("N")[..6], 50_000, 30, 7, 0);
        var typeId = type.GetProperty("id").GetGuid();
        await FollowUpIdAsync(admin);
        var doctor = await PractitionerAsync("Dr. NoShow");
        var patient = Guid.NewGuid();
        var older = await BookAsync(admin, Main, doctor, patient, new DateTimeOffset(2026, 10, 1, 4, 0, 0, TimeSpan.Zero), typeId);
        var later = await BookAsync(admin, Main, doctor, patient, new DateTimeOffset(2026, 10, 2, 4, 0, 0, TimeSpan.Zero), typeId);
        var noShow = await admin.PostAsync($"/api/v1/appointments/{later.GetProperty("id").GetGuid()}/no-show", null);
        Assert.Equal(HttpStatusCode.OK, noShow.StatusCode);

        var suggestion = await SuggestAsync(admin, Main, doctor, patient, new DateTimeOffset(2026, 10, 5, 4, 0, 0, TimeSpan.Zero));
        Assert.Equal(older.GetProperty("id").GetGuid(), suggestion.GetProperty("priorAppointmentId").GetGuid());
    }

    [Fact]
    public async Task A_future_booked_visit_does_not_open_the_window()
    {
        using var admin = AsAdmin();
        var type = await CreateTypeAsync(admin, "fut" + Guid.NewGuid().ToString("N")[..6], 50_000, 30, 7, 0);
        await FollowUpIdAsync(admin);
        var doctor = await PractitionerAsync("Dr. Future");
        var patient = Guid.NewGuid();
        await BookAsync(admin, Main, doctor, patient, new DateTimeOffset(2026, 10, 8, 4, 0, 0, TimeSpan.Zero), type.GetProperty("id").GetGuid());
        var suggestion = await SuggestAsync(admin, Main, doctor, patient, new DateTimeOffset(2026, 10, 9, 4, 0, 0, TimeSpan.Zero));
        Assert.False(suggestion.GetProperty("suggested").GetBoolean());
    }

    [Fact]
    public async Task Explicit_zero_window_closes_an_older_grant_and_a_null_window_does_not()
    {
        using var admin = AsAdmin();
        var granting = await CreateTypeAsync(admin, "gr" + Guid.NewGuid().ToString("N")[..6], 50_000, 30, 7, 0);
        var closed = await CreateTypeAsync(admin, "zr" + Guid.NewGuid().ToString("N")[..6], 10_000, 15, 0, 0);
        var emergency = (await FollowUpIdAsync(admin)) == Guid.Empty;
        Assert.False(emergency);
        var rows = await (await admin.GetAsync($"/api/v1/visit-types?branchId={Main}")).Content.ReadFromJsonAsync<List<JsonElement>>(Json);
        var emergencyId = rows!.Single(r => r.GetProperty("code").GetString() == "emergency").GetProperty("id").GetGuid();

        var doctor = await PractitionerAsync("Dr. Window");
        var kept = Guid.NewGuid();
        var prior = await BookAsync(admin, Main, doctor, kept, new DateTimeOffset(2026, 10, 1, 5, 0, 0, TimeSpan.Zero), granting.GetProperty("id").GetGuid());
        await BookAsync(admin, Main, doctor, kept, new DateTimeOffset(2026, 10, 2, 5, 0, 0, TimeSpan.Zero), emergencyId);
        var still = await SuggestAsync(admin, Main, doctor, kept, new DateTimeOffset(2026, 10, 5, 5, 0, 0, TimeSpan.Zero));
        Assert.Equal(prior.GetProperty("id").GetGuid(), still.GetProperty("priorAppointmentId").GetGuid());

        var closedPatient = Guid.NewGuid();
        await BookAsync(admin, Main, doctor, closedPatient, new DateTimeOffset(2026, 10, 1, 6, 0, 0, TimeSpan.Zero), granting.GetProperty("id").GetGuid());
        await BookAsync(admin, Main, doctor, closedPatient, new DateTimeOffset(2026, 10, 2, 6, 0, 0, TimeSpan.Zero), closed.GetProperty("id").GetGuid());
        var shut = await SuggestAsync(admin, Main, doctor, closedPatient, new DateTimeOffset(2026, 10, 5, 6, 0, 0, TimeSpan.Zero));
        Assert.False(shut.GetProperty("suggested").GetBoolean());
    }

    [Fact]
    public async Task Ist_window_includes_the_last_local_day_and_excludes_the_next()
    {
        using var admin = AsAdmin();
        var type = await CreateTypeAsync(admin, "ist" + Guid.NewGuid().ToString("N")[..6], 50_000, 30, 7, 0);
        await FollowUpIdAsync(admin);
        var doctor = await PractitionerAsync("Dr. Zone");
        var patient = Guid.NewGuid();
        await BookAsync(admin, Main, doctor, patient, new DateTimeOffset(2026, 10, 1, 18, 29, 0, TimeSpan.Zero), type.GetProperty("id").GetGuid());

        var inside = await SuggestAsync(admin, Main, doctor, patient, new DateTimeOffset(2026, 10, 8, 18, 29, 0, TimeSpan.Zero));
        Assert.True(inside.GetProperty("suggested").GetBoolean());
        var outside = await SuggestAsync(admin, Main, doctor, patient, new DateTimeOffset(2026, 10, 8, 18, 30, 0, TimeSpan.Zero));
        Assert.False(outside.GetProperty("suggested").GetBoolean());
    }

    [Fact]
    public async Task Client_end_and_a_short_slot_cannot_undercharge_or_overlap()
    {
        using var admin = AsAdmin();
        var type = await CreateTypeAsync(admin, "len" + Guid.NewGuid().ToString("N")[..6], 50_000, 30, null, null);
        var typeId = type.GetProperty("id").GetGuid();
        var doctor = await PractitionerAsync("Dr. Slot");
        var start = new DateTimeOffset(2026, 11, 2, 9, 0, 0, TimeSpan.Zero);
        var booked = await BookAsync(admin, Main, doctor, Guid.NewGuid(), start, typeId, clientMinutes: 5);
        Assert.Equal(start.AddMinutes(30), booked.GetProperty("endsAt").GetDateTimeOffset());
        Assert.Equal(50_000, booked.GetProperty("consultationFeePaise").GetInt64());

        var other = await PractitionerAsync("Dr. Overlap");
        var first = await admin.PostAsJsonAsync("/api/v1/appointments", new
        {
            branchId = Main, practitionerId = other, patientId = Guid.NewGuid(), startsAt = start, endsAt = start.AddMinutes(15),
        });
        Assert.Equal(HttpStatusCode.Created, first.StatusCode);
        var overlap = await admin.PostAsJsonAsync("/api/v1/appointments", new
        {
            branchId = Main, practitionerId = other, patientId = Guid.NewGuid(), startsAt = start, endsAt = start.AddMinutes(5), visitTypeId = typeId,
        });
        Assert.Equal(HttpStatusCode.Conflict, overlap.StatusCode);
    }

    [Fact]
    public async Task Second_override_updates_the_same_row_and_defaults_are_idempotent()
    {
        using var admin = AsAdmin();
        var firstList = await FollowUpIdAsync(admin);
        var secondList = await FollowUpIdAsync(admin);
        Assert.Equal(firstList, secondList);

        var type = await CreateTypeAsync(admin, "ov" + Guid.NewGuid().ToString("N")[..6], 10_000, 15, 3, 0);
        var id = type.GetProperty("id").GetGuid();
        var created = await admin.PostAsJsonAsync($"/api/v1/visit-types/{id}/overrides", new { branchId = East, feePaise = 100 });
        var updated = await admin.PostAsJsonAsync($"/api/v1/visit-types/{id}/overrides", new { branchId = East, feePaise = 250 });
        Assert.Equal(HttpStatusCode.OK, created.StatusCode);
        Assert.Equal(HttpStatusCode.OK, updated.StatusCode);
        var firstBody = await created.Content.ReadFromJsonAsync<JsonElement>(Json);
        var secondBody = await updated.Content.ReadFromJsonAsync<JsonElement>(Json);
        Assert.Equal(firstBody.GetProperty("id").GetGuid(), secondBody.GetProperty("id").GetGuid());
        Assert.Equal(250, secondBody.GetProperty("feePaise").GetInt64());
    }

    [Fact]
    public async Task Invalid_and_empty_visit_type_and_registration_input_is_rejected()
    {
        using var admin = AsAdmin();
        var badType = await admin.PostAsJsonAsync("/api/v1/visit-types", new { code = "X", name = " ", defaultFeePaise = -1, durationMinutes = 1, followUpValidDays = 400 });
        Assert.Equal(HttpStatusCode.BadRequest, badType.StatusCode);
        var typeBody = await badType.Content.ReadAsStringAsync();
        Assert.Contains("code", typeBody, StringComparison.Ordinal);
        Assert.Contains("defaultFeePaise", typeBody, StringComparison.Ordinal);

        var badDoctor = await admin.PostAsJsonAsync("/api/v1/practitioners", new { displayName = "  ", registrationNumber = "AB", phone = "12", email = "not-an-email" });
        Assert.Equal(HttpStatusCode.BadRequest, badDoctor.StatusCode);
        var doctorBody = await badDoctor.Content.ReadAsStringAsync();
        Assert.Contains("displayName", doctorBody, StringComparison.Ordinal);
        Assert.Contains("registrationNumber", doctorBody, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Receptionist_cannot_edit_masters_and_another_tenants_branch_is_not_found()
    {
        using var desk = factory.ClientAs(RoleUsers[HmsRoles.Receptionist]);
        Assert.Equal(HttpStatusCode.Forbidden, (await desk.PostAsJsonAsync("/api/v1/visit-types", new { code = "nope", name = "No", defaultFeePaise = 1, durationMinutes = 15 })).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await desk.PostAsJsonAsync("/api/v1/departments", new { name = "Nope" })).StatusCode);

        using var admin = AsAdmin();
        var type = await CreateTypeAsync(admin, "ct" + Guid.NewGuid().ToString("N")[..6], 10_000, 15, null, null);
        var cross = await admin.PostAsJsonAsync($"/api/v1/visit-types/{type.GetProperty("id").GetGuid()}/overrides", new { branchId = BetaMain, feePaise = 1 });
        Assert.Equal(HttpStatusCode.NotFound, cross.StatusCode);
        var list = await admin.GetAsync($"/api/v1/visit-types?branchId={BetaMain}");
        Assert.Equal(HttpStatusCode.NotFound, list.StatusCode);
    }

    [Fact]
    public async Task Inactive_department_is_rejected_and_an_existing_link_is_kept()
    {
        using var admin = AsAdmin();
        var created = await admin.PostAsJsonAsync("/api/v1/departments", new { name = "Ward " + Guid.NewGuid().ToString("N")[..6] });
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var departmentId = (await created.Content.ReadFromJsonAsync<JsonElement>(Json)).GetProperty("id").GetGuid();
        var doctor = await PractitionerAsync(new { displayName = "Dr. Dept", departmentId });
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync($"/api/v1/departments/{departmentId}", new { isActive = false })).StatusCode);

        var listed = await admin.GetFromJsonAsync<List<JsonElement>>("/api/v1/practitioners", Json);
        Assert.Equal(departmentId, listed!.Single(p => p.GetProperty("id").GetGuid() == doctor).GetProperty("departmentId").GetGuid());

        var rejected = await admin.PostAsJsonAsync("/api/v1/practitioners", new { displayName = "Dr. Late", departmentId });
        Assert.Equal(HttpStatusCode.BadRequest, rejected.StatusCode);
        Assert.Contains("departmentId", await rejected.Content.ReadAsStringAsync(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Duplicate_registration_is_rejected_and_does_not_save_the_doctor()
    {
        using var admin = AsAdmin();
        var first = await PractitionerAsync(new { displayName = "Dr. First", registrationNumber = "  kmc/2018/12345 " });
        var listed = await admin.GetFromJsonAsync<List<JsonElement>>("/api/v1/practitioners", Json);
        Assert.NotNull(listed);
        Assert.Equal("KMC/2018/12345", listed.Single(p => p.GetProperty("id").GetGuid() == first).GetProperty("registrationNumber").GetString());

        var before = listed.Count;
        var duplicate = await admin.PostAsJsonAsync("/api/v1/practitioners", new { displayName = "Dr. Second", registrationNumber = "KMC/2018/12345" });
        Assert.Equal(HttpStatusCode.Conflict, duplicate.StatusCode);
        Assert.Contains("already used", await duplicate.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        var after = await admin.GetFromJsonAsync<List<JsonElement>>("/api/v1/practitioners", Json);
        Assert.Equal(before, after!.Count);
        Assert.DoesNotContain(after, p => p.GetProperty("displayName").GetString() == "Dr. Second");

        var cleared = await admin.PatchAsJsonAsync($"/api/v1/practitioners/{first}", new { registrationNumber = "   " });
        Assert.Equal(HttpStatusCode.OK, cleared.StatusCode);
        Assert.Equal(JsonValueKind.Null, (await cleared.Content.ReadFromJsonAsync<JsonElement>(Json)).GetProperty("registrationNumber").ValueKind);
    }

    [Fact]
    public async Task Doctor_without_nmc_data_can_be_booked()
    {
        using var admin = AsAdmin();
        var first = await PractitionerAsync(new { displayName = "Dr. Plain A" });
        var second = await PractitionerAsync(new { displayName = "Dr. Plain B" });
        Assert.NotEqual(first, second);
        var listed = await admin.GetFromJsonAsync<List<JsonElement>>("/api/v1/practitioners", Json);
        Assert.Equal(JsonValueKind.Null, listed!.Single(p => p.GetProperty("id").GetGuid() == first).GetProperty("registrationNumber").ValueKind);
        var booked = await admin.PostAsJsonAsync("/api/v1/appointments", new
        {
            branchId = Main, practitionerId = first, patientId = Guid.NewGuid(),
            startsAt = new DateTimeOffset(2026, 11, 3, 9, 0, 0, TimeSpan.Zero),
            endsAt = new DateTimeOffset(2026, 11, 3, 9, 15, 0, TimeSpan.Zero),
        });
        Assert.Equal(HttpStatusCode.Created, booked.StatusCode);
        Assert.Equal(JsonValueKind.Null, (await booked.Content.ReadFromJsonAsync<JsonElement>(Json)).GetProperty("consultationFeePaise").ValueKind);
    }
}
