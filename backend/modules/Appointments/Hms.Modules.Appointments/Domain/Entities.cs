using Hms.SharedKernel.Domain;
using Hms.SharedKernel.Tenancy;

namespace Hms.Modules.Appointments.Domain;

/// <summary>appointment.practitioners: a bookable person, optionally linked to a staff account (D4).</summary>
public sealed class Practitioner : AuditableEntity, ITenantOwned
{
    public Guid TenantId { get; set; }
    public Guid? UserId { get; set; }
    public required string DisplayName { get; set; }
    public string? Specialty { get; set; }
    public bool IsActive { get; set; } = true;
}

/// <summary>appointment.schedules: weekly hours in branch-local wall-clock time (ISO weekday 1=Mon..7=Sun).</summary>
public sealed class Schedule : AuditableEntity, ITenantOwned
{
    public Guid TenantId { get; set; }
    public Guid PractitionerId { get; set; }
    public Guid BranchId { get; set; }
    public short Weekday { get; set; }
    public TimeOnly StartTime { get; set; }
    public TimeOnly EndTime { get; set; }
    public short SlotMinutes { get; set; } = 15;
    public DateOnly ValidFrom { get; set; }
    public DateOnly? ValidTo { get; set; }
    public bool IsActive { get; set; } = true;
}

/// <summary>
/// appointment.appointments. <see cref="Status"/> is DB-defaulted on insert ('booked') and the
/// lifecycle timestamps are owned by the transition trigger; EF never sends them.
/// </summary>
public sealed class Appointment : AuditableEntity, ITenantOwned
{
    public Guid TenantId { get; set; }
    public Guid BranchId { get; set; }
    public Guid PractitionerId { get; set; }
    public Guid PatientId { get; set; }
    public DateTimeOffset StartsAt { get; set; }
    public DateTimeOffset EndsAt { get; set; }
    public string Status { get; set; } = AppointmentStatus.Booked;
    public string? Reason { get; set; }
    public string? CancelReason { get; set; }
    public DateTimeOffset? CheckedInAt { get; set; }
    public DateTimeOffset? StartedAt { get; set; }
    public DateTimeOffset? CompletedAt { get; set; }
    public DateTimeOffset? CancelledAt { get; set; }
    /// <summary>Follow-up: the earlier visit (same tenant + patient, DB-checked). Set on insert only.</summary>
    public Guid? ParentAppointmentId { get; set; }
    /// <summary>Booked outside the practitioner's working hours by an admin override (audited).</summary>
    public bool HoursOverride { get; set; }
}

/// <summary>appointment.queue_entries: READ-ONLY for the API; written only by the check-in / queue RPCs.</summary>
public sealed class QueueEntry : AuditableEntity, ITenantOwned
{
    public Guid TenantId { get; set; }
    public Guid BranchId { get; set; }
    public DateOnly QueueDate { get; set; }
    public int TokenNo { get; set; }
    public Guid PatientId { get; set; }
    public Guid? AppointmentId { get; set; }
    public Guid? PractitionerId { get; set; }
    public string Status { get; set; } = QueueStatus.Waiting;
    public DateTimeOffset CheckedInAt { get; set; }
    public DateTimeOffset? CalledAt { get; set; }
    public DateTimeOffset? CompletedAt { get; set; }
    public DateTimeOffset? CancelledAt { get; set; }
}

public static class AppointmentStatus
{
    public const string Booked = "booked";
    public const string CheckedIn = "checked_in";
    public const string InConsultation = "in_consultation";
    public const string Completed = "completed";
    public const string Cancelled = "cancelled";
    public const string NoShow = "no_show";

    public static readonly IReadOnlySet<string> All = new HashSet<string>(StringComparer.Ordinal)
    {
        Booked, CheckedIn, InConsultation, Completed, Cancelled, NoShow,
    };

    /// <summary>Statuses that occupy the practitioner's time (DB exclusion constraint predicate).</summary>
    public static readonly IReadOnlySet<string> Blocking = new HashSet<string>(StringComparer.Ordinal)
    {
        Booked, CheckedIn, InConsultation, Completed,
    };
}

public static class QueueStatus
{
    public const string Waiting = "waiting";
    public const string InConsultation = "in_consultation";
    public const string Done = "done";
    public const string Cancelled = "cancelled";

    public static readonly IReadOnlySet<string> All = new HashSet<string>(StringComparer.Ordinal) { Waiting, InConsultation, Done, Cancelled };

    /// <summary>Statuses a client may request through PATCH /queue/{id}.</summary>
    public static readonly IReadOnlySet<string> Settable = new HashSet<string>(StringComparer.Ordinal) { InConsultation, Done, Cancelled };
}

/// <summary>
/// Patient summary embedded as { id, mrn, firstName, lastName, isDeleted } in appointment / queue
/// responses. Comes from the patients service's published function patient.patient_summary_v1
/// (never from patient.patients); not part of the EF model.
/// </summary>
public sealed class PatientRef
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public string Mrn { get; set; } = "";
    public string FirstName { get; set; } = "";
    public string LastName { get; set; } = "";
    /// <summary>patient.patient_summary_v1 is_deleted (the API embeds null for deleted patients).</summary>
    public bool IsDeleted { get; set; }
}
