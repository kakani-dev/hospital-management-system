using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Hms.IntegrationTests.Sprint2Qa;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Rules;

/// <summary>Business rules approved 2026-10-20 (migration 20261020140000), through the edge. Synthetic data only.</summary>
[Trait("Category", "Database")]
public sealed class BusinessRulesApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly Guid AlphaGeneral = Guid.Parse("c1111111-0000-4000-8000-000000000002"); // Mon/Tue 10:00-14:00 @ Alpha Main
    private static readonly Guid BetaDoctorPractitioner = Guid.Parse("c2222222-0000-4000-8000-000000000001"); // Mon 09:00-12:00 @ Beta Main
    private static readonly Guid BetaSeedAppointment = Guid.Parse("e2222222-0000-4000-8000-000000000001");

    /// <summary>A far-future Monday (IST) per test, so tests never collide on the seeded practitioners.</summary>
    private static DateTimeOffset Monday(int week, int hour, int minute = 0) =>
        TestDates.At(TestDates.FarMonday(week, years: 5), hour, minute); // far from other classes' days (#233)

    private static object Booking(Guid branch, Guid practitioner, Guid patient, DateTimeOffset start, Guid? parent = null, bool? overrideHours = null) => new
    {
        branchId = branch, practitionerId = practitioner, patientId = patient, startsAt = start, endsAt = start.AddMinutes(15),
        reason = "Synthetic rules test", parentAppointmentId = parent, overrideWorkingHours = overrideHours,
    };

    private static async Task<JsonElement> JsonAsync(HttpResponseMessage r) => await r.Content.ReadFromJsonAsync<JsonElement>();

    [Fact]
    public async Task Outside_working_hours_is_400_unless_an_admin_overrides_and_the_override_is_audited()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        var patient = await Qa.CreatePatientAsync(admin, AlphaMain, "Hours", Qa.NewSurname("Rules"));

        var inside = await reception.PostAsJsonAsync("/api/v1/appointments", Booking(AlphaMain, AlphaGeneral, patient.Id, Monday(1, 10)));
        Assert.Equal(HttpStatusCode.Created, inside.StatusCode);
        Assert.False((await JsonAsync(inside)).GetProperty("hoursOverride").GetBoolean());

        var outside = await reception.PostAsJsonAsync("/api/v1/appointments", Booking(AlphaMain, AlphaGeneral, patient.Id, Monday(1, 16)));
        Assert.Equal(HttpStatusCode.BadRequest, outside.StatusCode);
        Assert.Contains("outside_working_hours", (await JsonAsync(outside)).GetProperty("detail").GetString());

        var receptionOverride = await reception.PostAsJsonAsync("/api/v1/appointments", Booking(AlphaMain, AlphaGeneral, patient.Id, Monday(1, 16), overrideHours: true));
        Assert.Equal(HttpStatusCode.Forbidden, receptionOverride.StatusCode);

        var adminOverride = await admin.PostAsJsonAsync("/api/v1/appointments", Booking(AlphaMain, AlphaGeneral, patient.Id, Monday(1, 16), overrideHours: true));
        Assert.Equal(HttpStatusCode.Created, adminOverride.StatusCode);
        var id = (await JsonAsync(adminOverride)).GetProperty("id").GetGuid();
        Assert.True((await JsonAsync(await admin.GetAsync($"/api/v1/appointments/{id}"))).GetProperty("hoursOverride").GetBoolean());
        Assert.True(await Qa.ScalarAsync<bool>(
            "select exists (select 1 from audit.audit_log where table_name = 'appointments' and record_id = @id and (new_data ->> 'hours_override')::boolean and changed_by = @by)",
            ("id", id), ("by", AlphaAdmin)));
    }

    [Fact]
    public async Task Doctors_book_only_follow_ups_of_their_own_patients_and_follow_ups_link_the_earlier_visit()
    {
        using var doctor = factory.ClientAs(BetaDoctor, Beta);
        var fresh = await doctor.PostAsJsonAsync("/api/v1/appointments", Booking(BetaMain, BetaDoctorPractitioner, BetaPatientId, Monday(2, 9)));
        Assert.Equal(HttpStatusCode.Forbidden, fresh.StatusCode);

        var followUp = await doctor.PostAsJsonAsync("/api/v1/appointments", Booking(BetaMain, BetaDoctorPractitioner, BetaPatientId, Monday(2, 9), parent: BetaSeedAppointment));
        Assert.Equal(HttpStatusCode.Created, followUp.StatusCode);
        Assert.Equal(BetaSeedAppointment, (await JsonAsync(followUp)).GetProperty("parentAppointmentId").GetGuid());

        using var betaAdmin = factory.ClientAs(BetaAdmin, Beta);
        var other = await Qa.CreatePatientAsync(betaAdmin, BetaMain, "Other", Qa.NewSurname("Rules"));
        var mismatch = await betaAdmin.PostAsJsonAsync("/api/v1/appointments", Booking(BetaMain, BetaDoctorPractitioner, other.Id, Monday(2, 10), parent: BetaSeedAppointment));
        Assert.Equal(HttpStatusCode.BadRequest, mismatch.StatusCode);
        Assert.Contains("follow_up_patient_mismatch", (await JsonAsync(mismatch)).GetProperty("detail").GetString());

        // a parent from another tenant is unknown
        using var alphaAdmin = factory.ClientAs(AlphaAdmin, Alpha);
        var foreign = await alphaAdmin.PostAsJsonAsync("/api/v1/appointments", Booking(AlphaMain, AlphaGeneral, AlphaPatientId, Monday(2, 11), parent: BetaSeedAppointment));
        Assert.Equal(HttpStatusCode.BadRequest, foreign.StatusCode);
    }

    [Fact]
    public async Task A_doctor_cannot_book_a_follow_up_of_another_clinicians_visit()
    {
        var consultant = Guid.Parse("0d000000-0000-4000-8000-000000000001");
        var parent = Guid.Parse("e1111111-0000-4000-8000-000000000001");
        using var doctor = factory.ClientAs(consultant, Alpha, AlphaEast);
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var other = await Qa.CreatePractitionerAsync(admin);
        var when = Monday(4, 9);
        await TestSchedules.OpenDayAsync(AlphaEast, other.Id, when);

        var fresh = await doctor.PostAsJsonAsync("/api/v1/appointments", Booking(AlphaEast, other.Id, AlphaPatientId, when));
        Assert.Equal(HttpStatusCode.Forbidden, fresh.StatusCode);

        var atMain = await doctor.PostAsJsonAsync("/api/v1/appointments", Booking(AlphaMain, AlphaGeneral, AlphaPatientId, Monday(4, 10), parent: parent));
        Assert.Equal(HttpStatusCode.Forbidden, atMain.StatusCode);

        var followUp = await doctor.PostAsJsonAsync("/api/v1/appointments", Booking(AlphaEast, other.Id, AlphaPatientId, when, parent: parent));
        Assert.Equal(HttpStatusCode.Forbidden, followUp.StatusCode);
    }

    [Fact]
    public async Task Nurses_can_book()
    {
        var nurse = await CreateUserAsync("rules-nurse", (Alpha, AlphaMain, "nurse"));
        using var client = factory.ClientAs(nurse, Alpha);
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var patient = await Qa.CreatePatientAsync(admin, AlphaMain, "Nurse", Qa.NewSurname("Rules"));
        Assert.Equal(HttpStatusCode.Created,
            (await client.PostAsJsonAsync("/api/v1/appointments", Booking(AlphaMain, AlphaGeneral, patient.Id, Monday(3, 11)))).StatusCode);
    }

    [Fact]
    public async Task Branch_names_are_unique_per_hospital_ignoring_case_and_spaces()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var dup = await admin.PostAsJsonAsync("/api/v1/branches", new { code = $"r-{Guid.NewGuid():N}"[..12], name = "  alpha MAIN campus ", timezone = "Asia/Kolkata" });
        Assert.Equal(HttpStatusCode.Conflict, dup.StatusCode);
        Assert.Equal("duplicate_branch_name", (await JsonAsync(dup)).GetProperty("code").GetString());

        var name = $"Rules Wing {Guid.NewGuid():N}"[..20];
        var created = await admin.PostAsJsonAsync("/api/v1/branches", new { code = $"r-{Guid.NewGuid():N}"[..12], name, timezone = "Asia/Kolkata" });
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var rename = await admin.PatchAsJsonAsync($"/api/v1/branches/{(await JsonAsync(created)).GetProperty("id").GetGuid()}", new { name = "ALPHA EAST CLINIC" });
        Assert.Equal(HttpStatusCode.Conflict, rename.StatusCode);
        Assert.Equal("duplicate_branch_name", (await JsonAsync(rename)).GetProperty("code").GetString());

        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.Equal(HttpStatusCode.Created,
            (await beta.PostAsJsonAsync("/api/v1/branches", new { code = $"r-{Guid.NewGuid():N}"[..12], name, timezone = "Asia/Kolkata" })).StatusCode);
    }

    [Fact]
    public async Task Abha_number_is_optional_validated_formatted_and_unique_per_hospital()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var digits = string.Concat(Enumerable.Range(0, 14).Select(_ => Random.Shared.Next(10)));
        object Body(string? abha) => new { firstName = "Abha", lastName = Qa.NewSurname("Rules"), sex = "female", registeredBranchId = AlphaMain, abhaNumber = abha, ageYears = 30, noPhoneReason = "test fixture" };

        var created = await admin.PostAsJsonAsync("/api/v1/patients", Body(digits));
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var formatted = $"{digits[..2]}-{digits[2..6]}-{digits[6..10]}-{digits[10..]}";
        var createdBody = await JsonAsync(created);
        Assert.Equal(formatted, createdBody.GetProperty("abhaNumber").GetString());

        var duplicate = await admin.PostAsJsonAsync("/api/v1/patients", Body(formatted));
        Assert.Equal(HttpStatusCode.Conflict, duplicate.StatusCode);
        Assert.Equal("duplicate_abha", (await JsonAsync(duplicate)).GetProperty("code").GetString());

        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PostAsJsonAsync("/api/v1/patients", Body("1234"))).StatusCode);
        Assert.Equal(HttpStatusCode.Created, (await admin.PostAsJsonAsync("/api/v1/patients", Body(null))).StatusCode);

        var id = createdBody.GetProperty("id").GetGuid();
        var cleared = await admin.PatchAsJsonAsync($"/api/v1/patients/{id}", new { abhaNumber = (string?)null });
        Assert.Equal(HttpStatusCode.OK, cleared.StatusCode);
        Assert.Equal(JsonValueKind.Null, (await JsonAsync(cleared)).GetProperty("abhaNumber").ValueKind);
    }
}
