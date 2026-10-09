using System.Globalization;
using Hms.Modules.Appointments.Domain;

namespace Hms.Modules.Appointments.Endpoints;

// ---------------------------------------------------------------- practitioners
public sealed record PractitionerDto(Guid Id, Guid? UserId, string DisplayName, string? Specialty, bool IsActive)
{
    public static PractitionerDto From(Practitioner p) => new(p.Id, p.UserId, p.DisplayName, p.Specialty, p.IsActive);
}

public sealed record CreatePractitionerRequest(string? DisplayName, string? Specialty, Guid? UserId);

/// <summary>Absent/null = unchanged. Send specialty "" to clear it and unlinkUser = true to clear userId.</summary>
public sealed record UpdatePractitionerRequest(string? DisplayName, string? Specialty, Guid? UserId, bool? IsActive, bool? UnlinkUser);

// -------------------------------------------------------------------- schedules
/// <summary>Times are branch-local wall-clock "HH:mm"; weekday is ISO (1 = Monday … 7 = Sunday).</summary>
public sealed record ScheduleDto(
    Guid Id, Guid PractitionerId, Guid BranchId, int Weekday, string StartTime, string EndTime, int SlotMinutes,
    DateOnly ValidFrom, DateOnly? ValidTo, bool IsActive)
{
    public static ScheduleDto From(Schedule s) => new(
        s.Id, s.PractitionerId, s.BranchId, s.Weekday, HhMm.Format(s.StartTime), HhMm.Format(s.EndTime), s.SlotMinutes, s.ValidFrom, s.ValidTo, s.IsActive);
}

public sealed record CreateScheduleRequest(
    Guid PractitionerId, Guid BranchId, int? Weekday, string? StartTime, string? EndTime, int? SlotMinutes, DateOnly? ValidFrom, DateOnly? ValidTo);

/// <summary>Absent/null = unchanged. <c>clearValidTo</c> = true removes the end date.</summary>
public sealed record UpdateScheduleRequest(
    int? Weekday, string? StartTime, string? EndTime, int? SlotMinutes, DateOnly? ValidFrom, DateOnly? ValidTo, bool? ClearValidTo, bool? IsActive);

public sealed record SlotDto(Guid PractitionerId, Guid BranchId, DateTimeOffset StartsAt, DateTimeOffset EndsAt);

// ------------------------------------------------------------------ appointments
public sealed record AppointmentDto(
    Guid Id, Guid BranchId, Guid PractitionerId, Guid PatientId, DateTimeOffset StartsAt, DateTimeOffset EndsAt, string Status,
    string? Reason, string? CancelReason, DateTimeOffset? CheckedInAt, DateTimeOffset? StartedAt, DateTimeOffset? CompletedAt,
    DateTimeOffset? CancelledAt, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt)
{
    public static AppointmentDto From(Appointment a) => new(
        a.Id, a.BranchId, a.PractitionerId, a.PatientId, a.StartsAt.ToUniversalTime(), a.EndsAt.ToUniversalTime(), a.Status, a.Reason, a.CancelReason,
        a.CheckedInAt, a.StartedAt, a.CompletedAt, a.CancelledAt, a.CreatedAt, a.UpdatedAt);
}

public sealed record CreateAppointmentRequest(
    Guid BranchId, Guid PractitionerId, Guid PatientId, DateTimeOffset? StartsAt, DateTimeOffset? EndsAt, string? Reason);

public sealed record RescheduleAppointmentRequest(DateTimeOffset? StartsAt, DateTimeOffset? EndsAt, Guid? PractitionerId);

public sealed record CancelAppointmentRequest(string? Reason);

// ---------------------------------------------------------------------- queue
public sealed record QueueEntryDto(
    Guid Id, Guid BranchId, DateOnly QueueDate, int TokenNo, Guid PatientId, Guid? AppointmentId, Guid? PractitionerId, string Status,
    DateTimeOffset CheckedInAt, DateTimeOffset? CalledAt, DateTimeOffset? CompletedAt, DateTimeOffset? CancelledAt)
{
    public static QueueEntryDto From(QueueEntry q) => new(
        q.Id, q.BranchId, q.QueueDate, q.TokenNo, q.PatientId, q.AppointmentId, q.PractitionerId, q.Status,
        q.CheckedInAt, q.CalledAt, q.CompletedAt, q.CancelledAt);
}

public sealed record CheckInResultDto(Guid QueueEntryId, int TokenNo, DateOnly QueueDate, QueueEntryDto Entry);

public sealed record WalkInRequest(Guid BranchId, Guid PatientId, Guid? PractitionerId);

public sealed record UpdateQueueStatusRequest(string? Status);

/// <summary>"HH:mm" wall-clock times (24h).</summary>
public static class HhMm
{
    public static string Format(TimeOnly t) => t.ToString("HH:mm", CultureInfo.InvariantCulture);

    public static bool TryParse(string? value, out TimeOnly time) =>
        TimeOnly.TryParseExact(value, "HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out time);
}
