using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2Qa;

/// <summary>
/// Double booking (contract §2.5, §A.5, D5): no overlap per practitioner on the half-open range
/// [startsAt, endsAt) among booked/checked_in/in_consultation/completed; the DB exclusion constraint
/// (23P01) answers 409 appointment_overlap. Each test uses its own practitioner.
/// </summary>
[Trait("Category", "Database")]
public sealed class QaDoubleBookingApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private static async Task AssertOverlapAsync(HttpResponseMessage response)
    {
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
        Assert.Equal(QaCodes.AppointmentOverlap, await Qa.CodeAsync(response));
    }

    [Fact]
    public async Task Exact_partial_and_containing_overlaps_are_409_and_back_to_back_is_fine()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await Qa.CreatePractitionerAsync(admin);
        var p1 = await Qa.CreatePatientAsync(admin, AlphaMain, "Book", Qa.NewSurname("One"));
        var p2 = await Qa.CreatePatientAsync(admin, AlphaMain, "Book", Qa.NewSurname("Two"));
        var start = Qa.Future(hour: 10);

        await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, p1.Id, start, 30); // 10:00-10:30

        await AssertOverlapAsync(await Qa.BookAsync(admin, AlphaMain, practitioner.Id, p2.Id, start, 30));             // exact
        await AssertOverlapAsync(await Qa.BookAsync(admin, AlphaMain, practitioner.Id, p2.Id, start.AddMinutes(15), 30)); // tail
        await AssertOverlapAsync(await Qa.BookAsync(admin, AlphaMain, practitioner.Id, p2.Id, start.AddMinutes(-15), 30)); // head
        await AssertOverlapAsync(await Qa.BookAsync(admin, AlphaMain, practitioner.Id, p2.Id, start.AddMinutes(5), 10));  // inside
        await AssertOverlapAsync(await Qa.BookAsync(admin, AlphaMain, practitioner.Id, p2.Id, start.AddMinutes(-30), 90)); // around
        // Another branch does not help: the practitioner is the same person.
        await AssertOverlapAsync(await Qa.BookAsync(admin, AlphaEast, practitioner.Id, p2.Id, start.AddMinutes(10), 15));
        Assert.Equal(1, await Qa.AppointmentCountAsync(practitioner.Id));

        // Half-open: ends exactly when the next starts.
        await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, p2.Id, start.AddMinutes(30), 15);
        await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, p2.Id, start.AddMinutes(-15), 15);
        Assert.Equal(3, await Qa.AppointmentCountAsync(practitioner.Id));
    }

    [Fact]
    public async Task Other_practitioners_and_the_same_patient_with_another_practitioner_may_overlap()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var doctorA = await Qa.CreatePractitionerAsync(admin);
        var doctorB = await Qa.CreatePractitionerAsync(admin);
        var patient = await Qa.CreatePatientAsync(admin, AlphaMain, "Parallel", Qa.NewSurname("Visit"));
        var start = Qa.Future(dayOffset: 1, hour: 9);

        await Qa.BookOkAsync(admin, AlphaMain, doctorA.Id, patient.Id, start, 30);
        await Qa.BookOkAsync(admin, AlphaMain, doctorB.Id, patient.Id, start, 30); // Q2 default: no patient-side check
    }

    [Fact]
    public async Task Cancelled_and_no_show_free_the_time_but_completed_still_blocks()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await Qa.CreatePractitionerAsync(admin);
        var patient = await Qa.CreatePatientAsync(admin, AlphaMain, "Free", Qa.NewSurname("Time"));

        // Cancelled frees the slot.
        var future = Qa.Future(dayOffset: 2, hour: 9);
        var cancelled = await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, patient.Id, future, 20);
        Assert.Equal(HttpStatusCode.OK, (await admin.PostAsJsonAsync(QaRoutes.Cancel(cancelled.Id), new { reason = "Synthetic" })).StatusCode);
        await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, patient.Id, future, 20);

        // No-show (only once the start has passed) frees it too: a past slot earlier today
        // (earlier days cannot be booked, audit 2026-10-20).
        var past = await Qa.BranchTodayAtAsync(AlphaMain, 0);
        var noShow = await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, patient.Id, past, 20);
        var early = await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, patient.Id, Qa.Future(dayOffset: 3, hour: 9), 20);
        var tooEarly = await admin.PostAsync(QaRoutes.NoShow(early.Id), content: null);
        Assert.Equal(HttpStatusCode.Conflict, tooEarly.StatusCode);
        Assert.Equal(QaCodes.InvalidTransition, await Qa.CodeAsync(tooEarly));
        Assert.Equal("no_show", (await Qa.ReadAsync<QaAppointment>(await admin.PostAsync(QaRoutes.NoShow(noShow.Id), content: null), HttpStatusCode.OK)).Status);
        await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, patient.Id, past, 20);

        // Completed (walked through check-in -> in_consultation -> done today) keeps blocking.
        var other = await Qa.CreatePatientAsync(admin, AlphaMain, "Done", Qa.NewSurname("Visit"));
        var todayStart = await Qa.BranchTodayAtAsync(AlphaMain, 40);
        var visit = await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, other.Id, todayStart, 20);
        var entry = await Qa.CheckInOkAsync(admin, visit.Id);
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync(QaRoutes.QueueEntry(entry.QueueEntryId), new { status = "in_consultation" })).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await admin.PatchAsJsonAsync(QaRoutes.QueueEntry(entry.QueueEntryId), new { status = "done" })).StatusCode);
        Assert.Equal("completed", await Qa.AppointmentStatusAsync(visit.Id));
        await AssertOverlapAsync(await Qa.BookAsync(admin, AlphaMain, practitioner.Id, patient.Id, todayStart.AddMinutes(10), 20));
    }

    [Fact]
    public async Task Rescheduling_into_an_overlap_is_409_and_leaves_the_booking_unchanged()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await Qa.CreatePractitionerAsync(admin);
        var other = await Qa.CreatePractitionerAsync(admin);
        var patient = await Qa.CreatePatientAsync(admin, AlphaMain, "Move", Qa.NewSurname("Me"));
        var start = Qa.Future(dayOffset: 4, hour: 10);
        await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, patient.Id, start, 30);
        var mover = await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, patient.Id, start.AddHours(2), 30);
        await Qa.BookOkAsync(admin, AlphaMain, other.Id, patient.Id, start.AddHours(4), 30);

        await AssertOverlapAsync(await admin.PostAsJsonAsync(QaRoutes.Reschedule(mover.Id), new { startsAt = start.AddMinutes(15), endsAt = start.AddMinutes(45) }));
        await AssertOverlapAsync(await admin.PostAsJsonAsync(QaRoutes.Reschedule(mover.Id),
            new { startsAt = start.AddHours(4), endsAt = start.AddHours(4).AddMinutes(30), practitionerId = other.Id }));

        var unchanged = await Qa.ReadAsync<QaAppointment>(await admin.GetAsync(QaRoutes.Appointment(mover.Id)), HttpStatusCode.OK);
        Assert.Equal((practitioner.Id, mover.StartsAt, mover.EndsAt, "booked"), (unchanged.PractitionerId, unchanged.StartsAt, unchanged.EndsAt, unchanged.Status));

        var moved = await Qa.ReadAsync<QaAppointment>(
            await admin.PostAsJsonAsync(QaRoutes.Reschedule(mover.Id), new { startsAt = start.AddMinutes(30), endsAt = start.AddMinutes(60) }), HttpStatusCode.OK);
        Assert.Equal(start.AddMinutes(30), moved.StartsAt);
    }

    [Fact]
    public async Task Concurrent_bookings_of_one_slot_yield_exactly_one_201()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await Qa.CreatePractitionerAsync(admin);
        var patients = new List<QaPatient>();
        for (var i = 0; i < 6; i++)
        {
            patients.Add(await Qa.CreatePatientAsync(admin, AlphaMain, "Race", Qa.NewSurname($"P{i}")));
        }

        var start = Qa.Future(dayOffset: 5, hour: 11);
        var clients = patients.Select(_ => factory.ClientAs(AlphaAdmin, Alpha)).ToList();
        try
        {
            var responses = await Task.WhenAll(patients.Select((p, i) => Qa.BookAsync(clients[i], AlphaMain, practitioner.Id, p.Id, start, 15)));
            Assert.Single(responses, r => r.StatusCode == HttpStatusCode.Created);
            Assert.All(responses.Where(r => r.StatusCode != HttpStatusCode.Created), r => Assert.Equal(HttpStatusCode.Conflict, r.StatusCode));
            Assert.Equal(1, await Qa.AppointmentCountAsync(practitioner.Id));
        }
        finally
        {
            clients.ForEach(c => c.Dispose());
        }
    }

    [Fact]
    public async Task Invalid_time_ranges_are_400_not_409()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await Qa.CreatePractitionerAsync(admin);
        var patient = await Qa.CreatePatientAsync(admin, AlphaMain, "Bad", Qa.NewSurname("Range"));
        var start = Qa.Future(dayOffset: 6, hour: 9);

        Assert.Equal(HttpStatusCode.BadRequest, (await Qa.BookAsync(admin, AlphaMain, practitioner.Id, patient.Id, start, 0)).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await Qa.BookAsync(admin, AlphaMain, practitioner.Id, patient.Id, start, -15)).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await Qa.BookAsync(admin, AlphaMain, practitioner.Id, patient.Id, start, (8 * 60) + 1)).StatusCode);
        Assert.Equal(0, await Qa.AppointmentCountAsync(practitioner.Id));
    }
}
