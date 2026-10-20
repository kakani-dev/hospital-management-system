using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2Qa;

/// <summary>
/// Business-logic audit 2026-10-20: booking / rescheduling into an earlier branch-local day is 400;
/// same-day and future bookings still work.
/// </summary>
[Trait("Category", "Database")]
public sealed class QaBookingWindowApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Booking_or_rescheduling_into_an_earlier_day_is_400()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var practitioner = await Qa.CreatePractitionerAsync(admin);
        var patient = await Qa.CreatePatientAsync(admin, AlphaMain, "Window", Qa.NewSurname("Past"));
        var yesterday = (await Qa.BranchTodayAtAsync(AlphaMain, 0)).AddDays(-1).AddHours(9);

        var past = await Qa.BookAsync(admin, AlphaMain, practitioner.Id, patient.Id, yesterday, 15);
        Assert.Equal(HttpStatusCode.BadRequest, past.StatusCode);
        Assert.Equal(0, await Qa.AppointmentCountAsync(practitioner.Id));

        var ok = await Qa.BookOkAsync(admin, AlphaMain, practitioner.Id, patient.Id, Qa.Future(hour: 11), 15);
        var moveBack = await admin.PostAsJsonAsync(QaRoutes.Reschedule(ok.Id), new { startsAt = yesterday, endsAt = yesterday.AddMinutes(15) });
        Assert.Equal(HttpStatusCode.BadRequest, moveBack.StatusCode);
    }
}
