using System.Net.Http.Json;
using System.Text.Json;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2;

// Wire mirrors of the Sprint 2 API contract (SPRINT2-CONTRACT.md "API (Backend)").
public sealed record S2Candidate(Guid Id, string Mrn, List<string> MatchReasons);

public sealed record S2Patient(
    Guid Id, string Mrn, string FirstName, string LastName, DateOnly? DateOfBirth, Guid RegisteredBranchId, string? Phone,
    DateTimeOffset? DeletedAt, string? Email, List<S2Candidate>? DuplicateWarnings);

public sealed record S2Page<T>(List<T> Items, int Page, int PageSize, int TotalCount);

public sealed record S2Practitioner(Guid Id, Guid? UserId, string DisplayName, string? Specialty, bool IsActive);

public sealed record S2Schedule(Guid Id, Guid PractitionerId, Guid BranchId, int Weekday, string StartTime, string EndTime, int SlotMinutes);

public sealed record S2Slot(Guid PractitionerId, Guid BranchId, DateTimeOffset StartsAt, DateTimeOffset EndsAt);

public sealed record S2Appointment(
    Guid Id, Guid BranchId, Guid PractitionerId, Guid PatientId, DateTimeOffset StartsAt, DateTimeOffset EndsAt, string Status,
    string? CancelReason, DateTimeOffset? CheckedInAt, DateTimeOffset? CancelledAt, S2PatientRef? Patient = null);

public sealed record S2PatientRef(Guid Id, string Mrn, string FirstName, string LastName);

public sealed record S2QueueEntry(Guid Id, Guid BranchId, DateOnly QueueDate, int TokenNo, Guid PatientId, Guid? AppointmentId, string Status, S2PatientRef? Patient = null);

public sealed record S2CheckIn(Guid QueueEntryId, int TokenNo, DateOnly QueueDate, S2QueueEntry Entry);

internal static class S2
{
    public static string Unique(string prefix) => $"{prefix}{Guid.NewGuid():N}"[..16].ToUpperInvariant();

    public static async Task<string?> CodeAsync(HttpResponseMessage response)
    {
        var text = await response.Content.ReadAsStringAsync();
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        using var doc = JsonDocument.Parse(text);
        return doc.RootElement.TryGetProperty("code", out var code) ? code.GetString() : null;
    }

    public static async Task<S2Patient> CreatePatientAsync(HttpClient client, Guid branch, string? lastName = null, string? dob = null, string? phone = null)
    {
        var response = await client.PostAsJsonAsync("/api/v1/patients", new
        {
            mrn = Unique("S2-"), firstName = "Synth", lastName = lastName ?? Unique("Ln"), registeredBranchId = branch, dateOfBirth = dob, phone,
        });
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<S2Patient>())!;
    }

    public static async Task<S2Practitioner> CreatePractitionerAsync(HttpClient admin)
    {
        var response = await admin.PostAsJsonAsync("/api/v1/practitioners", new { displayName = $"Dr {Unique("P")} (synthetic)", specialty = "General" });
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<S2Practitioner>())!;
    }

    public static async Task<HttpResponseMessage> BookAsync(HttpClient client, Guid branch, Guid practitioner, Guid patient, DateTimeOffset start, int minutes = 15)
    {
        await TestSchedules.OpenDayAsync(branch, practitioner, start);
        return await client.PostAsJsonAsync("/api/v1/appointments", new
        {
            branchId = branch, practitionerId = practitioner, patientId = patient, startsAt = start, endsAt = start.AddMinutes(minutes), reason = "Synthetic visit",
        });
    }

    /// <summary>A far-future instant unique enough per test (practitioners are per test anyway).</summary>
    public static DateTimeOffset FutureSlot(int dayOffset = 0, int hour = 10, int minute = 0) =>
        new DateTimeOffset(2031, 3, 3, hour, minute, 0, TimeSpan.FromHours(5.5)).AddDays(dayOffset);

    /// <summary>Branch-local (Asia/Kolkata in the seed) "today" at the given time, as an instant.</summary>
    public static DateTimeOffset TodayAt(int hour, int minute = 0)
    {
        var ist = TimeSpan.FromHours(5.5);
        var today = DateTimeOffset.UtcNow.ToOffset(ist).Date;
        return new DateTimeOffset(today.Year, today.Month, today.Day, hour, minute, 0, ist);
    }

    public static async Task<long> ScalarLongAsync(string sql, params (string Name, object Value)[] parameters)
    {
        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(sql, conn);
        foreach (var (name, value) in parameters)
        {
            cmd.Parameters.AddWithValue(name, value);
        }

        return Convert.ToInt64(await cmd.ExecuteScalarAsync(), System.Globalization.CultureInfo.InvariantCulture);
    }

    public static Task<long> OutboxCountAsync(Guid practitionerId, string? eventType = null) =>
        ScalarLongAsync(
            "select count(*) from messaging.outbox where payload->>'practitioner_id' = @p and (@e = '' or event_type = @e)",
            ("p", practitionerId.ToString()), ("e", eventType ?? string.Empty));

    public static Task<long> AppointmentCountAsync(Guid practitionerId) =>
        ScalarLongAsync("select count(*) from appointment.appointments where practitioner_id = @p", ("p", practitionerId));
}
