using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2Qa;

/// <summary>
/// Cross-tenant 404-not-403 on EVERY Sprint 2 endpoint (contract §A.0 "404-not-403 (v4)", §A.1):
/// another tenant's id (patient, practitioner, appointment, queue entry, schedule or branch, in the
/// path, body or query) is indistinguishable from an unknown id: 404 <c>not_found</c>, and nothing
/// changes. Alpha's admin (tenant-wide, every role) attacks Beta's seed rows; a few reverse cases run
/// as Beta. Random ids prove 404 is also what "unknown" looks like.
/// </summary>
[Trait("Category", "Database")]
public sealed class QaCrossTenantNotFoundApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static readonly Guid Unknown = Guid.Parse("00000000-0000-4000-8000-0000000000aa");

    private sealed record Probe(string Name, HttpMethod Method, string Path, object? Body);

    private static readonly DateTimeOffset Start = new(2031, 9, 1, 10, 0, 0, TimeSpan.FromHours(5.5));
    private const string Day = "2031-09-01";

    /// <summary>Alpha admin -> Beta ids (seed rows from contract §5), for every route that takes an id.</summary>
    private static readonly Dictionary<string, Probe> ForeignProbes = BuildForeignProbes().ToDictionary(p => p.Name);

    private static readonly Dictionary<string, Probe> UnknownProbes = BuildUnknownProbes().ToDictionary(p => p.Name);

    public static TheoryData<string> AlphaAttacksBeta() => [.. ForeignProbes.Keys];

    public static TheoryData<string> UnknownIds() => [.. UnknownProbes.Keys];

    private static Probe[] BuildForeignProbes()
    {
        var bPatient = BetaPatientId;
        var bPr = QaSeed.BetaPractitioner;
        var bAppt = QaSeed.BetaAppointment;
        var bSchedule = QaSeed.BetaSchedule;
        var aPr = QaSeed.AlphaGeneralPractitioner;
        var aPatient = AlphaPatientId;
        return
        [
            // 2.1 patients
            new("POST patient at foreign branch", HttpMethod.Post, QaRoutes.Patients,
                new { mrn = "XT-S2QA-0001", firstName = "Cross", lastName = "Tenant", registeredBranchId = BetaMain, sex = "unknown", ageYears = 30, noPhoneReason = "test fixture" }),
            new("GET patient", HttpMethod.Get, QaRoutes.Patient(bPatient), null),
            new("PATCH patient", HttpMethod.Patch, QaRoutes.Patient(bPatient), new { firstName = "Hijack" }),
            new("PATCH own patient to foreign branch", HttpMethod.Patch, QaRoutes.Patient(aPatient), new { registeredBranchId = BetaMain }),
            new("DELETE patient", HttpMethod.Delete, QaRoutes.Patient(bPatient), null),
            new("POST restore patient", HttpMethod.Post, QaRoutes.Restore(bPatient), null),
            // 2.2 practitioners, schedules, slots
            new("GET practitioners at foreign branch", HttpMethod.Get, $"{QaRoutes.Practitioners}?branchId={BetaMain}", null),
            new("PATCH practitioner", HttpMethod.Patch, QaRoutes.Practitioner(bPr), new { displayName = "Hijack" }),
            new("POST schedule at foreign branch", HttpMethod.Post, QaRoutes.Schedules,
                new { practitionerId = aPr, branchId = BetaMain, weekday = 6, startTime = "07:00", endTime = "08:00" }),
            new("POST schedule for foreign practitioner", HttpMethod.Post, QaRoutes.Schedules,
                new { practitionerId = bPr, branchId = AlphaMain, weekday = 6, startTime = "07:00", endTime = "08:00" }),
            new("PATCH schedule", HttpMethod.Patch, QaRoutes.Schedule(bSchedule), new { isActive = false }),
            new("DELETE schedule", HttpMethod.Delete, QaRoutes.Schedule(bSchedule), null),
            new("GET slots at foreign branch", HttpMethod.Get, $"{QaRoutes.Slots}?branchId={BetaMain}&from={Day}&to={Day}", null),
            new("GET slots for foreign practitioner", HttpMethod.Get, $"{QaRoutes.Slots}?branchId={AlphaMain}&from={Day}&to={Day}&practitionerId={bPr}", null),
            // 2.2 appointments
            new("GET appointment", HttpMethod.Get, QaRoutes.Appointment(bAppt), null),
            new("POST appointment at foreign branch", HttpMethod.Post, QaRoutes.Appointments,
                new { branchId = BetaMain, practitionerId = aPr, patientId = aPatient, startsAt = Start, endsAt = Start.AddMinutes(15) }),
            new("POST appointment with foreign practitioner", HttpMethod.Post, QaRoutes.Appointments,
                new { branchId = AlphaMain, practitionerId = bPr, patientId = aPatient, startsAt = Start, endsAt = Start.AddMinutes(15) }),
            new("POST appointment for foreign patient", HttpMethod.Post, QaRoutes.Appointments,
                new { branchId = AlphaMain, practitionerId = aPr, patientId = bPatient, startsAt = Start, endsAt = Start.AddMinutes(15) }),
            new("POST reschedule", HttpMethod.Post, QaRoutes.Reschedule(bAppt), new { startsAt = Start, endsAt = Start.AddMinutes(15) }),
            new("POST reschedule own to foreign practitioner", HttpMethod.Post, QaRoutes.Reschedule(QaSeed.AlphaAppointment),
                new { startsAt = Start, endsAt = Start.AddMinutes(15), practitionerId = bPr }),
            new("POST cancel", HttpMethod.Post, QaRoutes.Cancel(bAppt), new { reason = "Hijack" }),
            new("POST no-show", HttpMethod.Post, QaRoutes.NoShow(bAppt), null),
            // 2.3 check-in and queue
            new("POST check-in", HttpMethod.Post, QaRoutes.CheckIn(bAppt), null),
            new("POST walk-in at foreign branch", HttpMethod.Post, QaRoutes.WalkIn, new { branchId = BetaMain, patientId = aPatient }),
            new("POST walk-in for foreign patient", HttpMethod.Post, QaRoutes.WalkIn, new { branchId = AlphaMain, patientId = bPatient }),
            new("POST walk-in with foreign practitioner", HttpMethod.Post, QaRoutes.WalkIn, new { branchId = AlphaMain, patientId = aPatient, practitionerId = bPr }),
            new("GET queue at foreign branch", HttpMethod.Get, $"{QaRoutes.Queue}?branchId={BetaMain}", null),
        ];
    }

    /// <summary>The same routes with ids that exist nowhere: must look exactly like the foreign case.</summary>
    private static Probe[] BuildUnknownProbes() =>
    [
        new("PATCH unknown patient", HttpMethod.Patch, QaRoutes.Patient(Unknown), new { firstName = "X" }),
        new("DELETE unknown patient", HttpMethod.Delete, QaRoutes.Patient(Unknown), null),
        new("POST restore unknown patient", HttpMethod.Post, QaRoutes.Restore(Unknown), null),
        new("POST patient at unknown branch", HttpMethod.Post, QaRoutes.Patients,
            new { mrn = "XT-S2QA-0002", firstName = "Cross", lastName = "Tenant", registeredBranchId = Unknown, sex = "unknown", ageYears = 30, noPhoneReason = "test fixture" }),
        new("GET practitioners at unknown branch", HttpMethod.Get, $"{QaRoutes.Practitioners}?branchId={Unknown}", null),
        new("PATCH unknown practitioner", HttpMethod.Patch, QaRoutes.Practitioner(Unknown), new { displayName = "X" }),
        new("PATCH unknown schedule", HttpMethod.Patch, QaRoutes.Schedule(Unknown), new { isActive = false }),
        new("DELETE unknown schedule", HttpMethod.Delete, QaRoutes.Schedule(Unknown), null),
        new("GET unknown appointment", HttpMethod.Get, QaRoutes.Appointment(Unknown), null),
        new("POST cancel unknown appointment", HttpMethod.Post, QaRoutes.Cancel(Unknown), new { reason = "X" }),
        new("POST check-in unknown appointment", HttpMethod.Post, QaRoutes.CheckIn(Unknown), null),
        new("PATCH unknown queue entry", HttpMethod.Patch, QaRoutes.QueueEntry(Unknown), new { status = "cancelled" }),
        new("GET queue at unknown branch", HttpMethod.Get, $"{QaRoutes.Queue}?branchId={Unknown}", null),
        new("GET slots at unknown branch", HttpMethod.Get, $"{QaRoutes.Slots}?branchId={Unknown}&from={Day}&to={Day}", null),
    ];

    private static async Task AssertNotFoundAsync(HttpClient client, Probe probe)
    {
        using var request = new HttpRequestMessage(probe.Method, probe.Path);
        if (probe.Body is not null)
        {
            request.Content = JsonContent.Create(probe.Body);
        }

        using var response = await client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        Assert.True(response.StatusCode == HttpStatusCode.NotFound, $"{probe.Name}: expected 404, got {(int)response.StatusCode}: {body}");
        Assert.Equal(QaCodes.NotFound, await Qa.CodeAsync(response));
        // No foreign data leaks into the problem details.
        Assert.DoesNotContain("BET-", body, StringComparison.Ordinal);
        Assert.DoesNotContain("Synthetic-Beta", body, StringComparison.Ordinal);
    }

    [Theory]
    [MemberData(nameof(AlphaAttacksBeta))]
    public async Task Alpha_admin_gets_404_for_Beta_ids(string probe)
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        await AssertNotFoundAsync(admin, ForeignProbes[probe]);
    }

    [Theory]
    [MemberData(nameof(UnknownIds))]
    public async Task Unknown_ids_are_404_too(string probe)
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        await AssertNotFoundAsync(admin, UnknownProbes[probe]);
    }

    [Fact]
    public async Task Beta_rows_are_unchanged_after_every_attack()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        foreach (var probe in ForeignProbes.Values)
        {
            using var request = new HttpRequestMessage(probe.Method, probe.Path);
            if (probe.Body is not null)
            {
                request.Content = JsonContent.Create(probe.Body);
            }

            (await admin.SendAsync(request)).Dispose();
        }

        Assert.Equal("booked", await Qa.AppointmentStatusAsync(QaSeed.BetaAppointment));
        Assert.Equal(QaSeed.BetaPractitioner,
            await Qa.ScalarAsync<Guid>("select practitioner_id from appointment.appointments where id = @id", ("id", QaSeed.BetaAppointment)));
        Assert.Null(await Qa.ScalarAsync<DateTimeOffset?>("select deleted_at from patient.patients where id = @id", ("id", BetaPatientId)));
        Assert.Equal("John", await Qa.ScalarAsync<string>("select first_name from patient.patients where id = @id", ("id", BetaPatientId)));
        Assert.Equal("Dr. Beta Doctor (synthetic)",
            await Qa.ScalarAsync<string>("select display_name from appointment.practitioners where id = @id", ("id", QaSeed.BetaPractitioner)));
        Assert.True(await Qa.ScalarAsync<bool>("select is_active from appointment.schedules where id = @id", ("id", QaSeed.BetaSchedule)));
        Assert.Equal(0L, await Qa.ScalarAsync<long>(
            "select count(*) from appointment.schedules where practitioner_id = @p and branch_id = @b", ("p", QaSeed.AlphaGeneralPractitioner), ("b", BetaMain)));
        Assert.Equal(0L, await Qa.ScalarAsync<long>("select count(*) from patient.patients where mrn like 'XT-S2QA-%'"));
        Assert.Equal(0L, await Qa.ScalarAsync<long>(
            "select count(*) from appointment.queue_entries where tenant_id = @a and branch_id = @b", ("a", Alpha), ("b", BetaMain)));
        Assert.Equal(0L, await Qa.ScalarAsync<long>(
            "select count(*) from appointment.appointments where tenant_id = @a and (branch_id = @b or practitioner_id = @p or patient_id = @x)",
            ("a", Alpha), ("b", BetaMain), ("p", QaSeed.BetaPractitioner), ("x", BetaPatientId)));
    }

    [Fact]
    public async Task Queue_entry_of_another_tenant_is_404_for_status_changes()
    {
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        var betaPatient = await Qa.CreatePatientAsync(beta, BetaMain, "Beta", Qa.NewSurname("Queue"));
        var entry = await Qa.WalkInOkAsync(beta, BetaMain, betaPatient.Id);

        using var alpha = factory.ClientAs(AlphaAdmin, Alpha);
        foreach (var status in new[] { "in_consultation", "done", "cancelled" })
        {
            var response = await alpha.PatchAsJsonAsync(QaRoutes.QueueEntry(entry.QueueEntryId), new { status });
            Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
            Assert.Equal(QaCodes.NotFound, await Qa.CodeAsync(response));
        }

        Assert.Equal("waiting", await Qa.ScalarAsync<string>("select status from appointment.queue_entries where id = @id", ("id", entry.QueueEntryId)));
        Assert.Equal(HttpStatusCode.OK, (await beta.PatchAsJsonAsync(QaRoutes.QueueEntry(entry.QueueEntryId), new { status = "cancelled" })).StatusCode);
    }

    [Fact]
    public async Task Tenant_wide_lists_never_include_the_other_tenants_rows()
    {
        using var alpha = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioners = await Qa.ReadAsync<List<QaPractitioner>>(await alpha.GetAsync(QaRoutes.Practitioners), HttpStatusCode.OK);
        Assert.Contains(practitioners, p => p.Id == QaSeed.AlphaGeneralPractitioner);
        Assert.DoesNotContain(practitioners, p => p.Id == QaSeed.BetaPractitioner);

        var schedules = await Qa.ReadAsync<List<QaSchedule>>(await alpha.GetAsync(QaRoutes.Schedules), HttpStatusCode.OK);
        Assert.Contains(schedules, s => s.Id == QaSeed.AlphaEastSchedule);
        Assert.DoesNotContain(schedules, s => s.Id == QaSeed.BetaSchedule || s.BranchId == BetaMain);

        var appointments = await Qa.ReadAsync<QaPaged<QaAppointment>>(
            await alpha.GetAsync($"{QaRoutes.Appointments}?from=2030-01-01T00:00:00Z&to=2030-01-31T00:00:00Z&pageSize=100"), HttpStatusCode.OK);
        Assert.Contains(appointments.Items, a => a.Id == QaSeed.AlphaAppointment);
        Assert.DoesNotContain(appointments.Items, a => a.Id == QaSeed.BetaAppointment || a.BranchId == BetaMain);

        // List filters naming another tenant's branch/patient/practitioner never surface its rows. The
        // contract's route tables list no 404 for these list GETs while §A.0 says a foreign id "in a
        // body/query" is 404, so either an empty 200 or a 404 passes here (flagged to the CTO).
        foreach (var path in new[]
        {
            $"{QaRoutes.Appointments}?branchId={BetaMain}",
            $"{QaRoutes.Appointments}?patientId={BetaPatientId}",
            $"{QaRoutes.Appointments}?practitionerId={QaSeed.BetaPractitioner}",
            $"{QaRoutes.Schedules}?branchId={BetaMain}",
            $"{QaRoutes.Schedules}?practitionerId={QaSeed.BetaPractitioner}",
        })
        {
            using var response = await alpha.GetAsync(path);
            var body = await response.Content.ReadAsStringAsync();
            Assert.True(response.StatusCode is HttpStatusCode.OK or HttpStatusCode.NotFound, $"{path}: {(int)response.StatusCode} {body}");
            if (response.StatusCode == HttpStatusCode.OK)
            {
                Assert.Matches(@"^(\[\]|\{""items"":\[\].*)$", body);
            }

            Assert.DoesNotContain(QaSeed.BetaAppointment.ToString(), body, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(QaSeed.BetaSchedule.ToString(), body, StringComparison.OrdinalIgnoreCase);
        }

        var dupes = await Qa.ReadAsync<QaDuplicates>(await alpha.PostAsJsonAsync(QaRoutes.PatientDuplicates,
            new { firstName = "John", lastName = "Synthetic-Beta", dateOfBirth = new DateOnly(1965, 9, 21), phone = "+1-555-0201" }), HttpStatusCode.OK);
        Assert.DoesNotContain(dupes.Candidates, c => c.Id == BetaPatientId);

        var search = await Qa.ReadAsync<QaPaged<QaPatient>>(await alpha.PostAsJsonAsync(QaRoutes.PatientSearch,
            new { dateOfBirth = new DateOnly(1965, 9, 21), includeDeleted = true }), HttpStatusCode.OK);
        Assert.DoesNotContain(search.Items, p => p.Id == BetaPatientId);
    }

    [Fact]
    public async Task Beta_gets_404_for_Alpha_ids_too()
    {
        using var beta = factory.ClientAs(BetaAdmin, Beta);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync(QaRoutes.Appointment(QaSeed.AlphaAppointment))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PostAsync(QaRoutes.CheckIn(QaSeed.AlphaAppointment), content: null)).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.PatchAsJsonAsync(QaRoutes.Practitioner(QaSeed.AlphaGeneralPractitioner), new { isActive = false })).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.DeleteAsync(QaRoutes.Schedule(QaSeed.AlphaEastSchedule))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.GetAsync($"{QaRoutes.Queue}?branchId={AlphaEast}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await beta.DeleteAsync(QaRoutes.Patient(AlphaPatientId))).StatusCode);
        Assert.Equal("booked", await Qa.AppointmentStatusAsync(QaSeed.AlphaAppointment));
    }
}
