using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2Qa;

/// <summary>POST /patients/{id}/merge folds a duplicate chart into the survivor. Tenant admin only.</summary>
[Trait("Category", "Database")]
public sealed class QaPatientMergeApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Admin_merge_repoints_visits_fills_blanks_and_hides_the_duplicate()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        using var reception = factory.ClientAs(AlphaReception, Alpha);
        using var beta = factory.ClientAs(BetaAdmin, Beta);

        var survivor = await Qa.ReadAsync<QaPatient>(await admin.PostAsJsonAsync(QaRoutes.Patients, new
        {
            firstName = "Keep",
            lastName = Qa.NewSurname("Merge"),
            registeredBranchId = AlphaMain,
            sex = "unknown", ageYears = 30, noPhoneReason = "test fixture"
        }), HttpStatusCode.Created);
        var email = $"merge-{Guid.NewGuid():N}@synthetic.example";
        var duplicate = await Qa.ReadAsync<QaPatient>(await admin.PostAsJsonAsync(QaRoutes.Patients, new
        {
            firstName = "Copy",
            lastName = Qa.NewSurname("Merge"),
            registeredBranchId = AlphaMain,
            sex = "female",
            dateOfBirth = new DateOnly(1991, 4, 5),
            email,
            phone = Qa.NewPhoneDigits(), ageYears = 30, noPhoneReason = "test fixture"
        }), HttpStatusCode.Created);

        var practitioner = await Qa.CreatePractitionerAsync(admin);
        var visit = await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, duplicate.Id, Qa.Future(dayOffset: 80, hour: 9));
        var queue = await Qa.WalkInOkAsync(admin, AlphaMain, duplicate.Id, practitioner.Id);

        Assert.Equal(HttpStatusCode.Forbidden, (await reception.PostAsJsonAsync(QaRoutes.Merge(survivor.Id), new
        {
            duplicatePatientId = duplicate.Id,
            reason = "Same person",
        })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PostAsJsonAsync(QaRoutes.Merge(survivor.Id), new
        {
            duplicatePatientId = duplicate.Id,
            reason = "Same person",
        })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PostAsJsonAsync(QaRoutes.Merge(survivor.Id), new
        {
            duplicatePatientId = survivor.Id,
            reason = "Same person",
        })).StatusCode);

        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsJsonAsync(QaRoutes.Merge(survivor.Id), new
        {
            duplicatePatientId = duplicate.Id,
            reason = "Same person, second chart",
        })).StatusCode);

        Assert.Equal(survivor.Id, await Qa.ScalarAsync<Guid>("select patient_id from appointment.appointments where id = @id", ("id", visit.Id)));
        Assert.Equal(survivor.Id, await Qa.ScalarAsync<Guid>("select patient_id from appointment.queue_entries where id = @id", ("id", queue.QueueEntryId)));
        Assert.Equal(email, await Qa.ScalarAsync<string>("select email from patient.patients where id = @id", ("id", survivor.Id)));
        Assert.Equal("female", await Qa.ScalarAsync<string>("select sex from patient.patients where id = @id", ("id", survivor.Id)));
        Assert.Equal(duplicate.Id, await Qa.ScalarAsync<Guid?>("select id from patient.patients where id = @id and merged_into_patient_id = @s and deleted_at is not null", ("id", duplicate.Id), ("s", survivor.Id)));
        Assert.Equal(1L, await Qa.ScalarAsync<long>(
            "select count(*) from audit.audit_log where table_name = 'patients' and record_id = @id and action = 'UPDATE' and new_data->>'merged_into_patient_id' = @s::text",
            ("id", duplicate.Id), ("s", survivor.Id)));
        Assert.Equal(1L, await Qa.ScalarAsync<long>(
            "select count(*) from messaging.outbox where aggregate_type = 'patient' and event_type = 'patient.merged' and aggregate_id = @id and payload->>'duplicate_patient_id' = @d::text",
            ("id", survivor.Id), ("d", duplicate.Id)));

        var kept = await Qa.ReadAsync<QaPatient>(await admin.GetAsync(QaRoutes.Patient(survivor.Id)), HttpStatusCode.OK);
        Assert.Equal(email, kept.Email);
        Assert.Equal(duplicate.Phone, kept.Phone);
        Assert.Equal(HttpStatusCode.NotFound, (await admin.GetAsync(QaRoutes.Patient(duplicate.Id))).StatusCode);
        var hidden = await Qa.ReadAsync<QaPaged<QaPatient>>(
            await admin.PostAsJsonAsync(QaRoutes.PatientSearch, new { search = duplicate.Mrn, includeDeleted = true }), HttpStatusCode.OK);
        Assert.DoesNotContain(hidden.Items, p => p.Id == duplicate.Id);

        Assert.Equal(HttpStatusCode.NoContent, (await admin.PostAsJsonAsync(QaRoutes.Merge(survivor.Id), new
        {
            duplicatePatientId = duplicate.Id,
            reason = "Same person, second chart",
        })).StatusCode);
        Assert.Equal(1L, await Qa.ScalarAsync<long>(
            "select count(*) from messaging.outbox where aggregate_type = 'patient' and event_type = 'patient.merged' and aggregate_id = @id",
            ("id", survivor.Id)));

        var restore = await admin.PostAsync(QaRoutes.Restore(duplicate.Id), content: null);
        Assert.Equal(HttpStatusCode.Conflict, restore.StatusCode);
        Assert.Equal("invalid_state", await Qa.CodeAsync(restore));
    }
}
