using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2Qa;

/// <summary>
/// Sprint 2.1 patient edit (PATCH, merge-patch) and soft delete / restore (contract §1.2-1.3, §A.3, D1, D2).
/// Every request goes through the edge; persisted state is read back as the DB owner.
/// </summary>
[Trait("Category", "Database")]
public sealed class QaPatientEditDeleteApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Patch_is_a_merge_patch_absent_fields_stay_and_explicit_null_clears()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var phone = Qa.NewPhoneDigits();
        var created = await Qa.CreatePatientAsync(admin, AlphaMain, "Edit", Qa.NewSurname("Merge"), new DateOnly(1980, 1, 2), phone);

        var renamed = await Qa.ReadAsync<QaPatient>(
            await admin.PatchAsJsonAsync(QaRoutes.Patient(created.Id), new { firstName = "Edited", email = "edited@patients.example" }), HttpStatusCode.OK);
        Assert.Equal(("Edited", created.LastName, created.Mrn, created.DateOfBirth, "+91" + phone, "edited@patients.example"),
            (renamed.FirstName, renamed.LastName, renamed.Mrn, renamed.DateOfBirth, renamed.Phone, renamed.Email));

        var cleared = await Qa.ReadAsync<QaPatient>(
            await admin.PatchAsJsonAsync(QaRoutes.Patient(created.Id), new { phone = (string?)null, dateOfBirth = (DateOnly?)null }), HttpStatusCode.OK);
        Assert.Null(cleared.Phone);
        Assert.Null(cleared.DateOfBirth);
        Assert.Equal(("Edited", "edited@patients.example"), (cleared.FirstName, cleared.Email));

        var detail = await Qa.ReadAsync<QaPatient>(await admin.GetAsync(QaRoutes.Patient(created.Id)), HttpStatusCode.OK);
        Assert.Equal(cleared with { DuplicateWarnings = detail.DuplicateWarnings }, detail);

        // Audit columns are DB-managed: updated_by is the caller, created_by unchanged.
        Assert.Equal(AlphaAdmin, await Qa.ScalarAsync<Guid>("select updated_by from patient.patients where id = @id", ("id", created.Id)));
    }

    [Fact]
    public async Task Patch_rejects_mrn_change_unknown_properties_and_invalid_values_without_writing()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var created = await Qa.CreatePatientAsync(admin, AlphaMain, "Immutable", Qa.NewSurname("Mrn"));

        var mrn = await admin.PatchAsJsonAsync(QaRoutes.Patient(created.Id), new { mrn = Qa.NewMrn("NEW") });
        Assert.Equal(HttpStatusCode.BadRequest, mrn.StatusCode);
        Assert.Contains("mrn", await Qa.ErrorFieldsAsync(mrn));

        // §A.0: a tenantId in any body is ignored (never accepted); other unknown properties are 400 (§A.3).
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync(QaRoutes.Patient(created.Id), new { tenantId = Beta })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PatchAsJsonAsync(QaRoutes.Patient(created.Id), new { createdBy = AlphaReception })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PatchAsJsonAsync(QaRoutes.Patient(created.Id), new { firstName = (string?)null })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PatchAsJsonAsync(QaRoutes.Patient(created.Id), new { phone = new string('1', 33) })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PatchAsJsonAsync(QaRoutes.Patient(created.Id), new { email = "no-at-sign" })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest,
            (await admin.PatchAsJsonAsync(QaRoutes.Patient(created.Id), new { dateOfBirth = DateOnly.FromDateTime(DateTime.UtcNow).AddDays(3) })).StatusCode);

        var after = await Qa.ReadAsync<QaPatient>(await admin.GetAsync(QaRoutes.Patient(created.Id)), HttpStatusCode.OK);
        Assert.Equal((created.Mrn, created.FirstName, created.Phone, created.Email), (after.Mrn, after.FirstName, after.Phone, after.Email));
        Assert.Equal(Alpha, await Qa.ScalarAsync<Guid>("select tenant_id from patient.patients where id = @id", ("id", created.Id)));
    }

    [Fact]
    public async Task Soft_delete_hides_the_patient_records_who_and_why_and_keeps_the_mrn_reserved()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        using var reception = factory.ClientAs(AlphaReception, Alpha); // receptionist @Main (seed)
        var patient = await Qa.CreatePatientAsync(reception, AlphaMain, "Deleted", Qa.NewSurname("Soft"));

        var delete = new HttpRequestMessage(HttpMethod.Delete, QaRoutes.Patient(patient.Id)) { Content = JsonContent.Create(new { reason = "Registered twice (synthetic)" }) };
        Assert.Equal(HttpStatusCode.NoContent, (await reception.SendAsync(delete)).StatusCode);

        // Persisted: deleted_at/deleted_by/deletion_reason set by the RPC, row still there.
        Assert.NotNull(await Qa.ScalarAsync<DateTimeOffset?>("select deleted_at from patient.patients where id = @id", ("id", patient.Id)));
        Assert.Equal(AlphaReception, await Qa.ScalarAsync<Guid>("select deleted_by from patient.patients where id = @id", ("id", patient.Id)));
        Assert.Equal("Registered twice (synthetic)", await Qa.ScalarAsync<string>("select deletion_reason from patient.patients where id = @id", ("id", patient.Id)));

        // Hidden from detail (admins too), list and search; a second delete and an edit are 404.
        Assert.Equal(HttpStatusCode.NotFound, (await reception.GetAsync(QaRoutes.Patient(patient.Id))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.GetAsync(QaRoutes.Patient(patient.Id))).StatusCode);
        var search = await Qa.ReadAsync<QaPaged<QaPatient>>(await admin.PostAsJsonAsync(QaRoutes.PatientSearch, new { search = patient.Mrn }), HttpStatusCode.OK);
        Assert.Empty(search.Items);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.DeleteAsync(QaRoutes.Patient(patient.Id))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PatchAsJsonAsync(QaRoutes.Patient(patient.Id), new { firstName = "Zombie" })).StatusCode);

        // includeDeleted is admin-only and shows the row with deletedAt.
        Assert.Equal(HttpStatusCode.Forbidden,
            (await reception.PostAsJsonAsync(QaRoutes.PatientSearch, new { search = patient.Mrn, includeDeleted = true })).StatusCode);
        var withDeleted = await Qa.ReadAsync<QaPaged<QaPatient>>(
            await admin.PostAsJsonAsync(QaRoutes.PatientSearch, new { search = patient.Mrn, includeDeleted = true }), HttpStatusCode.OK);
        Assert.NotNull(Assert.Single(withDeleted.Items).DeletedAt);

        // The MRN stays reserved (D1): it is never handed out again (a typed MRN is ignored).
        var reuse = await Qa.ReadAsync<QaPatient>(
            await admin.PostAsJsonAsync(QaRoutes.Patients, new { mrn = patient.Mrn, firstName = "Reuse", lastName = "Attempt", registeredBranchId = AlphaMain, sex = "unknown", ageYears = 30, noPhoneReason = "test fixture" }),
            HttpStatusCode.Created);
        Assert.NotEqual(patient.Mrn, reuse.Mrn);
    }

    [Fact]
    public async Task Restore_is_admin_only_and_brings_the_patient_back_editable()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        var patient = await Qa.CreatePatientAsync(admin, AlphaMain, "Restore", Qa.NewSurname("Back"));

        // Not deleted yet: restore is 404.
        Assert.Equal(HttpStatusCode.NotFound, (await admin.PostAsync(QaRoutes.Restore(patient.Id), content: null)).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync(QaRoutes.Patient(patient.Id))).StatusCode);

        Assert.Equal(HttpStatusCode.Forbidden, (await reception.PostAsync(QaRoutes.Restore(patient.Id), content: null)).StatusCode);
        Assert.NotNull(await Qa.ScalarAsync<DateTimeOffset?>("select deleted_at from patient.patients where id = @id", ("id", patient.Id)));

        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsync(QaRoutes.Restore(patient.Id), content: null)).StatusCode);
        Assert.Null(await Qa.ScalarAsync<DateTimeOffset?>("select deleted_at from patient.patients where id = @id", ("id", patient.Id)));
        Assert.Null(await Qa.ScalarAsync<Guid?>("select deleted_by from patient.patients where id = @id", ("id", patient.Id)));

        Assert.Equal(HttpStatusCode.OK, (await reception.GetAsync(QaRoutes.Patient(patient.Id))).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await reception.PatchAsJsonAsync(QaRoutes.Patient(patient.Id), new { firstName = "Restored" })).StatusCode);
    }

    [Fact]
    public async Task Delete_is_any_receptionist_in_the_hospital_and_not_a_view_only_role()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var patient = await Qa.CreatePatientAsync(admin, AlphaEast, "Delete", Qa.NewSurname("Who"));

        var receptionAtMain = await CreateUserAsync("s2qa-del-rcp-main", (Alpha, AlphaMain, "receptionist"));
        var nurseAtEast = await CreateUserAsync("s2qa-del-nurse-east", (Alpha, AlphaEast, "nurse"));
        var doctorTenantWide = await CreateUserAsync("s2qa-del-doctor", (Alpha, null, "doctor"));

        foreach (var user in new[] { nurseAtEast, doctorTenantWide })
        {
            using var client = factory.ClientAs(user, Alpha);
            Assert.Equal(HttpStatusCode.Forbidden, (await client.DeleteAsync(QaRoutes.Patient(patient.Id))).StatusCode);
        }

        Assert.Null(await Qa.ScalarAsync<DateTimeOffset?>("select deleted_at from patient.patients where id = @id", ("id", patient.Id)));

        using var allowed = factory.ClientAs(receptionAtMain, Alpha);
        var tooLong = new HttpRequestMessage(HttpMethod.Delete, QaRoutes.Patient(patient.Id)) { Content = JsonContent.Create(new { reason = new string('x', 501) }) };
        Assert.Equal(HttpStatusCode.BadRequest, (await allowed.SendAsync(tooLong)).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await allowed.DeleteAsync(QaRoutes.Patient(patient.Id))).StatusCode);
        Assert.NotNull(await Qa.ScalarAsync<DateTimeOffset?>("select deleted_at from patient.patients where id = @id", ("id", patient.Id)));
    }

    [Fact]
    public async Task Delete_with_an_open_appointment_or_queue_entry_is_409_invalid_state_until_it_is_closed()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await Qa.CreatePractitionerAsync(admin);

        // Open (booked) appointment blocks the delete (D2: no cascade-cancel).
        var booked = await Qa.CreatePatientAsync(admin, AlphaMain, "Open", Qa.NewSurname("Appt"));
        var appointment = await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, booked.Id, Qa.Future(hour: 9));
        var blocked = await admin.DeleteAsync(QaRoutes.Patient(booked.Id));
        Assert.Equal(HttpStatusCode.Conflict, blocked.StatusCode);
        Assert.Equal(QaCodes.InvalidState, await Qa.CodeAsync(blocked));
        Assert.Equal(HttpStatusCode.OK, (await admin.GetAsync(QaRoutes.Patient(booked.Id))).StatusCode);

        Assert.Equal(HttpStatusCode.OK, (await admin.PostAsJsonAsync(QaRoutes.Cancel(appointment.Id), new { reason = "Synthetic" })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync(QaRoutes.Patient(booked.Id))).StatusCode);

        // API v2: the embedded patient is null once the patient is soft-deleted; the appointment stays readable.
        var history = await Qa.ReadAsync<QaAppointment>(await admin.GetAsync(QaRoutes.Appointment(appointment.Id)), HttpStatusCode.OK);
        Assert.Equal((booked.Id, "cancelled"), (history.PatientId, history.Status));
        Assert.Null(history.Patient);

        // A waiting walk-in queue entry blocks it too.
        var waiting = await Qa.CreatePatientAsync(admin, AlphaMain, "Open", Qa.NewSurname("Queue"));
        var entry = await Qa.WalkInOkAsync(admin, AlphaMain, waiting.Id);
        var blockedByQueue = await admin.DeleteAsync(QaRoutes.Patient(waiting.Id));
        Assert.Equal(HttpStatusCode.Conflict, blockedByQueue.StatusCode);
        Assert.Equal(QaCodes.InvalidState, await Qa.CodeAsync(blockedByQueue));

        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync(QaRoutes.QueueEntry(entry.QueueEntryId), new { status = "cancelled" })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync(QaRoutes.Patient(waiting.Id))).StatusCode);
    }

    [Fact]
    public async Task Booking_or_checking_in_a_soft_deleted_patient_is_404()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await Qa.CreatePractitionerAsync(admin);
        var patient = await Qa.CreatePatientAsync(admin, AlphaMain, "Gone", Qa.NewSurname("Deleted"));
        Assert.Equal(HttpStatusCode.NoContent, (await admin.DeleteAsync(QaRoutes.Patient(patient.Id))).StatusCode);

        Assert.Equal(HttpStatusCode.NotFound, (await Qa.BookAsync(admin, AlphaMain, practitioner.Id, patient.Id, Qa.Future(hour: 11))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound,
            (await admin.PostAsJsonAsync(QaRoutes.WalkIn, new { branchId = AlphaMain, patientId = patient.Id })).StatusCode);
        Assert.Equal(0, await Qa.AppointmentCountAsync(practitioner.Id));
    }
}
