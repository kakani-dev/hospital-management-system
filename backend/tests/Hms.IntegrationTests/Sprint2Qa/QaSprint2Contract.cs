using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.Sprint2Qa;

/// <summary>
/// Sprint 2 API contract (/workspace/SPRINT2-CONTRACT.md, DB v4 + "API (Backend)" v2), in one place so
/// that a contract change is a one-line edit. QA's regression tests are written against the contract,
/// not the implementation: they are expected to be red on s2/qa alone and green once s2/db and
/// s2/backend merge. Everything is Qa*-prefixed so it never clashes with Backend's Sprint2/S2* helpers.
/// </summary>
internal static class QaRoutes
{
    public const string Patients = "/api/v1/patients";
    public const string PatientSearch = "/api/v1/patients/search";
    public const string PatientDuplicates = "/api/v1/patients/duplicates";
    public const string Practitioners = "/api/v1/practitioners";
    public const string Schedules = "/api/v1/schedules";
    public const string Slots = "/api/v1/slots";
    public const string Appointments = "/api/v1/appointments";
    public const string Queue = "/api/v1/queue";
    public const string WalkIn = "/api/v1/queue/walk-in";
    public const string Branches = "/api/v1/branches";

    public static string Patient(Guid id) => $"{Patients}/{id}";
    public static string Restore(Guid id) => $"{Patients}/{id}/restore";
    public static string Practitioner(Guid id) => $"{Practitioners}/{id}";
    public static string Schedule(Guid id) => $"{Schedules}/{id}";
    public static string Appointment(Guid id) => $"{Appointments}/{id}";
    public static string Reschedule(Guid id) => $"{Appointments}/{id}/reschedule";
    public static string Cancel(Guid id) => $"{Appointments}/{id}/cancel";
    public static string NoShow(Guid id) => $"{Appointments}/{id}/no-show";
    public static string CheckIn(Guid id) => $"{Appointments}/{id}/check-in";
    public static string QueueEntry(Guid id) => $"{Queue}/{id}";
}

/// <summary>Problem-detail <c>code</c> values from contract §A.1.</summary>
internal static class QaCodes
{
    public const string AppointmentOverlap = "appointment_overlap";
    public const string AlreadyCheckedIn = "already_checked_in";
    public const string InvalidTransition = "invalid_transition";
    public const string InvalidState = "invalid_state";
    public const string NotFound = "not_found";
    public const string Forbidden = "forbidden";
}

/// <summary>Synthetic seed rows from contract §5 (supabase/seed.sql on s2/db).</summary>
internal static class QaSeed
{
    public static readonly Guid AlphaConsultantPractitioner = Guid.Parse("c1111111-0000-4000-8000-000000000001");
    public static readonly Guid AlphaGeneralPractitioner = Guid.Parse("c1111111-0000-4000-8000-000000000002");
    public static readonly Guid BetaPractitioner = Guid.Parse("c2222222-0000-4000-8000-000000000001");
    public static readonly Guid AlphaEastSchedule = Guid.Parse("d1111111-0000-4000-8000-000000000001");
    public static readonly Guid BetaSchedule = Guid.Parse("d2222222-0000-4000-8000-000000000001");
    public static readonly Guid AlphaAppointment = Guid.Parse("e1111111-0000-4000-8000-000000000001");
    public static readonly Guid BetaAppointment = Guid.Parse("e2222222-0000-4000-8000-000000000001");
}

// Wire mirrors of the contract DTOs (deserialization only; unknown fields are ignored).
public sealed record QaDuplicateCandidate(
    Guid Id, string Mrn, string FirstName, string LastName, DateOnly? DateOfBirth, string? Phone, Guid RegisteredBranchId, List<string> MatchReasons);

public sealed record QaPatient(
    Guid Id, string Mrn, string FirstName, string LastName, DateOnly? DateOfBirth, string Sex, Guid RegisteredBranchId, string? Phone,
    DateTimeOffset? DeletedAt, string? Email, List<QaDuplicateCandidate>? DuplicateWarnings);

public sealed record QaDuplicates(List<QaDuplicateCandidate> Candidates);

public sealed record QaPaged<T>(List<T> Items, int Page, int PageSize, int TotalCount);

public sealed record QaPractitioner(Guid Id, Guid? UserId, string DisplayName, string? Specialty, bool IsActive);

public sealed record QaSchedule(
    Guid Id, Guid PractitionerId, Guid BranchId, int Weekday, string StartTime, string EndTime, int SlotMinutes, DateOnly ValidFrom, DateOnly? ValidTo, bool IsActive);

public sealed record QaSlot(Guid PractitionerId, Guid BranchId, DateTimeOffset StartsAt, DateTimeOffset EndsAt);

/// <summary>API v2: embedded on every AppointmentDto / QueueEntryDto; null when soft-deleted or not readable.</summary>
public sealed record QaPatientRef(Guid Id, string Mrn, string FirstName, string LastName);

public sealed record QaAppointment(
    Guid Id, Guid BranchId, Guid PractitionerId, Guid PatientId, DateTimeOffset StartsAt, DateTimeOffset EndsAt, string Status,
    string? Reason, string? CancelReason, DateTimeOffset? CheckedInAt, DateTimeOffset? CancelledAt, QaPatientRef? Patient);

public sealed record QaQueueEntry(
    Guid Id, Guid BranchId, DateOnly QueueDate, int TokenNo, Guid PatientId, Guid? AppointmentId, Guid? PractitionerId, string Status, DateTimeOffset CheckedInAt,
    QaPatientRef? Patient);

public sealed record QaCheckIn(Guid QueueEntryId, int TokenNo, DateOnly QueueDate, QaQueueEntry Entry);

public sealed record QaBranch(Guid Id, string Code, string Name, string Timezone, bool IsActive);

/// <summary>Request helpers that go through the API (hms_api_login + RLS) and fixture helpers as the DB owner.</summary>
internal static class Qa
{
    public static string NewMrn(string prefix) => $"{prefix}-{Guid.NewGuid():N}"[..Math.Min(32, prefix.Length + 13)].ToUpperInvariant();

    /// <summary>A unique synthetic 10-digit national number, so phone matches never collide across tests/runs.</summary>
    public static string NewPhoneDigits() => $"9{Random.Shared.NextInt64(100_000_000, 999_999_999)}";

    /// <summary>
    /// A unique surname that sorts AFTER the seed's "Synthetic-*" rows, so first-page assertions in
    /// older suites (lists ordered by last name) never get pushed off by QA's rows on a shared database.
    /// </summary>
    public static string NewSurname(string prefix) => $"Zz-{prefix}-{Guid.NewGuid():N}"[..Math.Min(43, prefix.Length + 16)];

    public static async Task<string?> CodeAsync(HttpResponseMessage response)
    {
        var text = await response.Content.ReadAsStringAsync();
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        try
        {
            using var doc = JsonDocument.Parse(text);
            return doc.RootElement.ValueKind == JsonValueKind.Object && doc.RootElement.TryGetProperty("code", out var code) ? code.GetString() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static async Task<IReadOnlyCollection<string>> ErrorFieldsAsync(HttpResponseMessage response)
    {
        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        return doc.RootElement.TryGetProperty("errors", out var errors)
            ? [.. errors.EnumerateObject().Select(p => p.Name.ToLowerInvariant())]
            : [];
    }

    public static async Task<T> ReadAsync<T>(HttpResponseMessage response, HttpStatusCode expected)
    {
        var body = await response.Content.ReadAsStringAsync();
        Assert.True(response.StatusCode == expected, $"expected {(int)expected}, got {(int)response.StatusCode}: {body}");
        return JsonSerializer.Deserialize<T>(body, JsonSerializerOptions.Web)!;
    }

    public static async Task<QaPatient> CreatePatientAsync(
        HttpClient client, Guid branch, string? firstName = null, string? lastName = null, DateOnly? dob = null, string? phone = null, string prefix = "QA")
    {
        var response = await client.PostAsJsonAsync(QaRoutes.Patients, new
        {
            mrn = NewMrn(prefix),
            firstName = firstName ?? "Synth",
            lastName = lastName ?? NewSurname("Qa"),
            dateOfBirth = dob,
            sex = "female",
            registeredBranchId = branch,
            phone,
        });
        return await ReadAsync<QaPatient>(response, HttpStatusCode.Created);
    }

    public static async Task<QaPractitioner> CreatePractitionerAsync(HttpClient admin, string? displayName = null)
    {
        var response = await admin.PostAsJsonAsync(QaRoutes.Practitioners, new { displayName = displayName ?? $"Dr {NewSurname("Qa")} (synthetic)", specialty = "General Medicine" });
        var practitioner = await ReadAsync<QaPractitioner>(response, HttpStatusCode.Created);
        await TestSchedules.OpenAllHoursAsync(practitioner.Id);
        return practitioner;
    }

    /// <summary>A new branch in the admin's tenant: its OPD token counter starts empty (deterministic token order).</summary>
    public static async Task<QaBranch> CreateBranchAsync(HttpClient admin, string timezone = "Asia/Kolkata")
    {
        var code = $"qa-{Guid.NewGuid():N}"[..20];
        var response = await admin.PostAsJsonAsync(QaRoutes.Branches, new { code, name = $"QA branch {code} (synthetic)", timezone });
        var branch = await ReadAsync<QaBranch>(response, HttpStatusCode.Created);
        await TestSchedules.OpenBranchAllHoursAsync(branch.Id);
        return branch;
    }

    public static Task<HttpResponseMessage> BookAsync(
        HttpClient client, Guid branch, Guid practitioner, Guid patient, DateTimeOffset start, int minutes = 15, string? reason = "Synthetic visit") =>
        client.PostAsJsonAsync(QaRoutes.Appointments, new
        {
            branchId = branch, practitionerId = practitioner, patientId = patient, startsAt = start, endsAt = start.AddMinutes(minutes), reason,
        });

    public static async Task<QaAppointment> BookOkAsync(HttpClient client, Guid branch, Guid practitioner, Guid patient, DateTimeOffset start, int minutes = 15) =>
        await ReadAsync<QaAppointment>(await BookAsync(client, branch, practitioner, patient, start, minutes), HttpStatusCode.Created);

    public static async Task<QaCheckIn> CheckInOkAsync(HttpClient client, Guid appointment) =>
        await ReadAsync<QaCheckIn>(await client.PostAsync(QaRoutes.CheckIn(appointment), content: null), HttpStatusCode.Created);

    public static async Task<QaCheckIn> WalkInOkAsync(HttpClient client, Guid branch, Guid patient, Guid? practitioner = null) =>
        await ReadAsync<QaCheckIn>(await client.PostAsJsonAsync(QaRoutes.WalkIn, new { branchId = branch, patientId = patient, practitionerId = practitioner }), HttpStatusCode.Created);

    /// <summary>A far-future, branch-independent instant (2031) for bookings that are never checked in.</summary>
    public static DateTimeOffset Future(int dayOffset = 0, int hour = 10, int minute = 0) =>
        new DateTimeOffset(2031, 6, 2, hour, minute, 0, TimeSpan.FromHours(5.5)).AddDays(dayOffset);

    public static async Task<TimeZoneInfo> BranchZoneAsync(Guid branch) =>
        TimeZoneInfo.FindSystemTimeZoneById((await ScalarAsync<string>("select identity.branch_time_zone_v1(@b)", ("b", branch)))!);

    /// <summary>Branch-local "today" (the date check-in and the queue use, contract §3.1/D6).</summary>
    public static async Task<DateOnly> BranchTodayAsync(Guid branch) =>
        DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, await BranchZoneAsync(branch)).DateTime);

    /// <summary>Branch-local today + <paramref name="minutesAfterMidnight"/>, as an instant (always on the branch-local today).</summary>
    public static async Task<DateTimeOffset> BranchTodayAtAsync(Guid branch, int minutesAfterMidnight)
    {
        var zone = await BranchZoneAsync(branch);
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, zone).DateTime);
        var local = today.ToDateTime(TimeOnly.MinValue).AddMinutes(minutesAfterMidnight);
        return new DateTimeOffset(local, zone.GetUtcOffset(local));
    }

    public static async Task<T?> ScalarAsync<T>(string sql, params (string Name, object? Value)[] parameters)
    {
        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(sql, conn);
        foreach (var (name, value) in parameters)
        {
            cmd.Parameters.AddWithValue(name, value ?? DBNull.Value);
        }

        var result = await cmd.ExecuteScalarAsync();
        return result switch
        {
            null or DBNull => default,
            DateTime utc when typeof(T) == typeof(DateTimeOffset) || typeof(T) == typeof(DateTimeOffset?) =>
                (T)(object)new DateTimeOffset(DateTime.SpecifyKind(utc, DateTimeKind.Utc)), // timestamptz is read as a UTC DateTime
            _ => (T)result,
        };
    }

    public static Task<string?> AppointmentStatusAsync(Guid id) =>
        ScalarAsync<string>("select status from appointment.appointments where id = @id", ("id", id));

    public static Task<long> AppointmentCountAsync(Guid practitioner) =>
        ScalarAsync<long>("select count(*) from appointment.appointments where practitioner_id = @p", ("p", practitioner));
}
