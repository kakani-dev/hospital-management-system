using System.Net;
using System.Net.Http.Json;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2;

/// <summary>GET /slots?durationMinutes= offers only starts where the whole visit fits the hours and no booking.</summary>
[Trait("Category", "Database")]
public sealed class VisitLengthSlotsApiTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    // A far-future Tuesday.
    private static readonly DateOnly Day = TestDates.FarMonday(weeks: 39).AddDays(1);
    private static DateTimeOffset At(int hour, int minute = 0) => TestDates.At(Day, hour, minute);

    [Fact]
    public async Task Slots_respect_the_visit_length_and_every_offered_slot_can_be_booked()
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var pr = await S2.CreatePractitionerAsync(admin);
        var patient = await S2.CreatePatientAsync(admin, AlphaMain);
        var hours = new { practitionerId = pr.Id, branchId = AlphaMain, weekday = 2, startTime = "09:00", endTime = "10:00", slotMinutes = 15, validFrom = TestDates.YearsAgo(1) };
        Assert.Equal(HttpStatusCode.Created, (await admin.PostAsJsonAsync("/api/v1/schedules", hours)).StatusCode);
        Assert.Equal(HttpStatusCode.Created, (await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, At(9, 30))).StatusCode);

        var url = $"/api/v1/slots?branchId={AlphaMain}&date={TestDates.Iso(Day)}&practitionerId={pr.Id}";
        var plain = await admin.GetFromJsonAsync<List<S2Slot>>(url);
        Assert.Equal([At(9), At(9, 15), At(9, 45)], plain!.Select(s => s.StartsAt).ToList());
        Assert.All(plain!, s => Assert.Equal(TimeSpan.FromMinutes(15), s.EndsAt - s.StartsAt));

        // 09:15 would overlap the 09:30 booking and 09:45 would run past 10:00.
        var thirty = await admin.GetFromJsonAsync<List<S2Slot>>(url + "&durationMinutes=30");
        var only = Assert.Single(thirty!);
        Assert.Equal(At(9), only.StartsAt);
        Assert.Equal(At(9, 30), only.EndsAt);
        Assert.Empty((await admin.GetFromJsonAsync<List<S2Slot>>(url + "&durationMinutes=90"))!);

        var booked = await S2.BookAsync(admin, AlphaMain, pr.Id, patient.Id, only.StartsAt, minutes: 30);
        Assert.Equal(HttpStatusCode.Created, booked.StatusCode);
        Assert.Empty((await admin.GetFromJsonAsync<List<S2Slot>>(url + "&durationMinutes=30"))!);
    }

    [Theory]
    [InlineData(4)]
    [InlineData(481)]
    public async Task An_out_of_range_visit_length_is_400(int minutes)
    {
        using var admin = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await admin.GetAsync($"/api/v1/slots?branchId={AlphaMain}&date={TestDates.Iso(Day)}&durationMinutes={minutes}");
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("durationMinutes", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);
    }
}
