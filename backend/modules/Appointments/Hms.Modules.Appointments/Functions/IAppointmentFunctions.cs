namespace Hms.Modules.Appointments.Functions;

public sealed record IssuedToken(Guid QueueEntryId, int TokenNo, DateOnly QueueDate);

public sealed record FreeSlot(Guid PractitionerId, Guid BranchId, DateTimeOffset SlotStart, DateTimeOffset SlotEnd);

/// <summary>
/// The appointment / queue RPCs owned by the database (SPRINT2-CONTRACT §2.3, §3.3, D11). They run on
/// the request's DbContext transaction as <c>authenticated</c> with the caller's claims. Errors are
/// SQLSTATEs (mapped by HmsProblems).
/// </summary>
public interface IAppointmentFunctions
{
    /// <summary>Free future starts. With <paramref name="durationMinutes"/>, only starts where the whole visit fits the
    /// working window and overlaps no booking; the slot then ends at start + duration. Null keeps one schedule slot.</summary>
    Task<IReadOnlyList<FreeSlot>> AvailableSlotsAsync(Guid tenantId, Guid branchId, DateOnly fromDate, DateOnly toDate, Guid? practitionerId, int? durationMinutes, CancellationToken ct);

    /// <summary><c>appointment.check_in</c> for a booked appointment (D6).</summary>
    Task<IssuedToken> CheckInAsync(Guid tenantId, Guid branchId, Guid patientId, Guid appointmentId, CancellationToken ct);

    /// <summary><c>appointment.check_in_walk_in</c> (D11).</summary>
    Task<IssuedToken> CheckInWalkInAsync(Guid branchId, Guid patientId, Guid? practitionerId, CancellationToken ct);

    /// <summary><c>appointment.set_queue_status</c>; the linked appointment follows.</summary>
    /// <summary><c>appointment.assert_bookable_window</c>: future and inside an active schedule (branch-local).</summary>
    Task AssertBookableWindowAsync(Guid tenantId, Guid branchId, Guid practitionerId, DateTimeOffset startsAt, DateTimeOffset endsAt, bool overrideHours, CancellationToken ct);

    Task SetQueueStatusAsync(Guid queueEntryId, string status, CancellationToken ct);

    /// <summary><c>appointment.close_queue_day</c>: waiting tokens on that branch-local day become expired.</summary>
    Task<int> CloseQueueDayAsync(Guid tenantId, Guid branchId, DateOnly queueDate, CancellationToken ct);
}
