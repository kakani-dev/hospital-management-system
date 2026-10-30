using System.Globalization;
using Npgsql;

namespace Hms.IntegrationTests;

/// <summary>
/// Relative dates for API tests (#232, #233). No literal calendar dates: everything is derived from
/// the real clock and the seed branch's configured time zone, so tests neither rot nor depend on
/// the time of day they run.
/// </summary>
internal static class TestDates
{
    private static readonly Lazy<TimeZoneInfo> Zone = new(() =>
    {
        using var conn = new NpgsqlConnection(HmsApiFactory.AdminConnection);
        conn.Open();
        using var cmd = new NpgsqlCommand("select identity.branch_time_zone_v1(@b)", conn);
        cmd.Parameters.AddWithValue("b", HmsApiFactory.AlphaMain);
        return TimeZoneInfo.FindSystemTimeZoneById((string)cmd.ExecuteScalar()!);
    });

    /// <summary>The seed tenant's time zone (tenant settings, not a constant).</summary>
    public static TimeZoneInfo SeedZone => Zone.Value;

    /// <summary>Branch-local today in the seed zone.</summary>
    public static DateOnly Today => DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, SeedZone).DateTime);

    /// <summary>
    /// A Monday about <paramref name="years"/> years ahead, plus <paramref name="weeks"/> weeks, so
    /// different test classes get different far-future days that always stay in the future.
    /// </summary>
    public static DateOnly FarMonday(int weeks = 0, int years = 3)
    {
        var d = Today.AddYears(years);
        while (d.DayOfWeek != DayOfWeek.Monday) d = d.AddDays(1);
        return d.AddDays(7 * weeks);
    }

    /// <summary>The given local date and time in the seed zone, as an instant.</summary>
    public static DateTimeOffset At(DateOnly date, int hour, int minute = 0)
    {
        var local = date.ToDateTime(new TimeOnly(hour, minute));
        return new DateTimeOffset(local, SeedZone.GetUtcOffset(local));
    }

    private static readonly Lazy<DateOnly> Seeded = new(() =>
    {
        using var conn = new NpgsqlConnection(HmsApiFactory.AdminConnection);
        conn.Open();
        using var cmd = new NpgsqlCommand(
            "select (a.starts_at at time zone identity.branch_time_zone_v1(a.branch_id))::date::text from appointment.appointments a where a.id = @id", conn);
        cmd.Parameters.AddWithValue("id", Guid.Parse("e1111111-0000-4000-8000-000000000001"));
        return DateOnly.ParseExact((string)cmd.ExecuteScalar()!, "yyyy-MM-dd", CultureInfo.InvariantCulture);
    });

    /// <summary>
    /// The Monday the seed books its sample appointments on (#233). Read from the database, because
    /// seed.sql moves it forward with the clock; never assume a calendar date here.
    /// </summary>
    public static DateOnly SeedMonday => Seeded.Value;

    public static string Iso(DateOnly date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    /// <summary>An ISO date <paramref name="years"/> years (plus days) from today, e.g. batch expiry or licence end.</summary>
    public static string YearsAhead(int years, int days = 0) => Iso(Today.AddYears(years).AddDays(days));

    public static string YearsAgo(int years) => Iso(Today.AddYears(-years));
}
