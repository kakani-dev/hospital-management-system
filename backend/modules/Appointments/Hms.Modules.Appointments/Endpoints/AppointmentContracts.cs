using System.Globalization;
using Hms.Modules.Appointments.Domain;

namespace Hms.Modules.Appointments.Endpoints;

// ---------------------------------------------------------------- practitioners
/// <param name="IsDeleted">Only ever true for admins listing with includeDeleted (restore).</param>
public sealed record PractitionerDto(Guid Id, Guid? UserId, string DisplayName, string? Specialty, bool IsActive, bool IsDeleted = false)
{
    public static PractitionerDto From(Practitioner p) => new(p.Id, p.UserId, p.DisplayName, p.Specialty, p.IsActive, p.IsDeleted);
}

public sealed record CreatePractitionerRequest(string? DisplayName, string? Specialty, Guid? UserId);

/// <summary>Absent/null = unchanged. Send specialty "" to clear it and unlinkUser = true to clear userId.</summary>
public sealed record UpdatePractitionerRequest(string? DisplayName, string? Specialty, Guid? UserId, bool? IsActive, bool? UnlinkUser);

// -------------------------------------------------------------------- schedules
/// <summary>Times are branch-local wall-clock "HH:mm"; weekday is ISO (1 = Monday … 7 = Sunday).</summary>
public sealed record ScheduleDto(
    Guid Id, Guid PractitionerId, Guid BranchId, int Weekday, string StartTime, string EndTime, int SlotMinutes,
    DateOnly ValidFrom, DateOnly? ValidTo, bool IsActive, bool IsDeleted = false)
{
    public static ScheduleDto From(Schedule s) => new(
        s.Id, s.PractitionerId, s.BranchId, s.Weekday, HhMm.Format(s.StartTime), HhMm.Format(s.EndTime), s.SlotMinutes, s.ValidFrom, s.ValidTo, s.IsActive, s.IsDeleted);
}

public sealed record CreateScheduleRequest(
    Guid PractitionerId, Guid BranchId, int? Weekday, string? StartTime, string? EndTime, int? SlotMinutes, DateOnly? ValidFrom, DateOnly? ValidTo);

/// <summary>Absent/null = unchanged. <c>clearValidTo</c> = true removes the end date.</summary>
public sealed record UpdateScheduleRequest(
    int? Weekday, string? StartTime, string? EndTime, int? SlotMinutes, DateOnly? ValidFrom, DateOnly? ValidTo, bool? ClearValidTo, bool? IsActive);

public sealed record SlotDto(Guid PractitionerId, Guid BranchId, DateTimeOffset StartsAt, DateTimeOffset EndsAt);

public sealed record PractitionerBranchDto(
    Guid Id, Guid PractitionerId, Guid BranchId, bool IsActive, string? ConsultationRoom, int? ConsultationFeeCents)
{
    public static PractitionerBranchDto From(PractitionerBranch m) =>
        new(m.Id, m.PractitionerId, m.BranchId, m.IsActive, m.ConsultationRoom, m.ConsultationFeeCents);
}

public sealed record CreatePractitionerBranchRequest(Guid PractitionerId, Guid BranchId, string? ConsultationRoom, int? ConsultationFeeCents);

/// <summary>Absent = unchanged. consultationRoom "" clears the room; clearFee removes the fee.</summary>
public sealed record UpdatePractitionerBranchRequest(bool? IsActive, string? ConsultationRoom, int? ConsultationFeeCents, bool? ClearFee);

public sealed record ScheduleOverrideDto(
    Guid Id, Guid PractitionerId, Guid BranchId, DateOnly Date, bool IsLeave, string? StartTime, string? EndTime, int? SlotMinutes, bool IsActive)
{
    public static ScheduleOverrideDto From(ScheduleOverride o) => new(
        o.Id, o.PractitionerId, o.BranchId, o.OverrideDate, o.IsLeave,
        o.StartTime is { } s ? HhMm.Format(s) : null,
        o.EndTime is { } e ? HhMm.Format(e) : null,
        o.SlotMinutes, o.IsActive);
}

public sealed record CreateScheduleOverrideRequest(
    Guid PractitionerId, Guid BranchId, DateOnly? Date, bool? IsLeave, string? StartTime, string? EndTime, int? SlotMinutes);

public sealed record UpdateScheduleOverrideRequest(bool? IsLeave, string? StartTime, string? EndTime, int? SlotMinutes, bool? IsActive);

public sealed record SchedulingSettingsDto(int TravelBufferMinutes);

public sealed record UpdateSchedulingSettingsRequest(int? TravelBufferMinutes);

/// <param name="Kind">appointment, hours, or leave.</param>
public sealed record MyDayItemDto(
    string Kind, Guid BranchId, DateTimeOffset StartsAt, DateTimeOffset EndsAt, Guid? AppointmentId, string? Status, PatientRefDto? Patient);

public sealed record MyDayDto(Guid? PractitionerId, string? DisplayName, DateOnly Date, IReadOnlyList<MyDayItemDto> Items);

// ------------------------------------------------------------------ appointments
public sealed record AppointmentDto(
    Guid Id, Guid BranchId, Guid PractitionerId, Guid PatientId, DateTimeOffset StartsAt, DateTimeOffset EndsAt, string Status,
    string? Reason, string? CancelReason, DateTimeOffset? CheckedInAt, DateTimeOffset? StartedAt, DateTimeOffset? CompletedAt,
    DateTimeOffset? CancelledAt, DateTimeOffset CreatedOn, DateTimeOffset UpdatedOn, PatientRefDto? Patient,
    Guid? ParentAppointmentId = null, bool HoursOverride = false)
{
    public static AppointmentDto From(Appointment a, PatientRef? patient) => new(
        a.Id, a.BranchId, a.PractitionerId, a.PatientId, a.StartsAt.ToUniversalTime(), a.EndsAt.ToUniversalTime(), a.Status, a.Reason, a.CancelReason,
        a.CheckedInAt, a.StartedAt, a.CompletedAt, a.CancelledAt, a.CreatedOn, a.UpdatedOn, PatientRefDto.From(patient),
        a.ParentAppointmentId, a.HoursOverride);
}

/// <summary>Embedded patient; null when the caller cannot read the patient (RLS) or it is soft-deleted.</summary>
public sealed record PatientRefDto(Guid Id, string Mrn, string FirstName, string LastName)
{
    public static PatientRefDto? From(PatientRef? p) => p is null ? null : new(p.Id, p.Mrn, p.FirstName, p.LastName);
}

/// <param name="ParentAppointmentId">Follow-up of this earlier visit (same patient). Required for doctors (own follow-ups only).</param>
/// <param name="OverrideWorkingHours">Admins only: book outside the practitioner's working hours (audited).</param>
public sealed record CreateAppointmentRequest(
    Guid BranchId, Guid PractitionerId, Guid PatientId, DateTimeOffset? StartsAt, DateTimeOffset? EndsAt, string? Reason,
    Guid? ParentAppointmentId = null, bool? OverrideWorkingHours = null);

public sealed record RescheduleAppointmentRequest(DateTimeOffset? StartsAt, DateTimeOffset? EndsAt, Guid? PractitionerId, bool? OverrideWorkingHours = null);

public sealed record CancelAppointmentRequest(string? Reason);

// ---------------------------------------------------------------------- queue
public sealed record QueueEntryDto(
    Guid Id, Guid BranchId, DateOnly QueueDate, int TokenNo, Guid PatientId, Guid? AppointmentId, Guid? PractitionerId, string Status,
    DateTimeOffset CheckedInAt, DateTimeOffset? CalledAt, DateTimeOffset? CompletedAt, DateTimeOffset? CancelledAt, PatientRefDto? Patient)
{
    public static QueueEntryDto From(QueueEntry q, PatientRef? patient) => new(
        q.Id, q.BranchId, q.QueueDate, q.TokenNo, q.PatientId, q.AppointmentId, q.PractitionerId, q.Status,
        q.CheckedInAt, q.CalledAt, q.CompletedAt, q.CancelledAt, PatientRefDto.From(patient));
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
