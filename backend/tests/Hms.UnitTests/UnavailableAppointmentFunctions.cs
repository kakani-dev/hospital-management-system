using Hms.Modules.Appointments.Functions;

namespace Hms.UnitTests;

/// <summary>
/// The appointment RPCs are DB-owned (covered by the integration tests); in-process every call behaves
/// like the DB for an id it cannot see: P0002 (foreign / unknown) -> 404.
/// </summary>
internal sealed class UnavailableAppointmentFunctions : IAppointmentFunctions
{
    public Task<IReadOnlyList<FreeSlot>> AvailableSlotsAsync(Guid tenantId, Guid branchId, DateOnly fromDate, DateOnly toDate, Guid? practitionerId, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<FreeSlot>>([]);

    public Task<IssuedToken> CheckInAsync(Guid tenantId, Guid branchId, Guid patientId, Guid appointmentId, CancellationToken ct) =>
        throw new FakeDbException("P0002", "appointment not found");

    public Task<IssuedToken> CheckInWalkInAsync(Guid branchId, Guid patientId, Guid? practitionerId, CancellationToken ct) =>
        throw new FakeDbException("P0002", "patient not found");

    public Task AssertBookableWindowAsync(Guid tenantId, Guid branchId, Guid practitionerId, DateTimeOffset startsAt, DateTimeOffset endsAt, bool overrideHours, CancellationToken ct) =>
        Task.CompletedTask;

    public Task SetQueueStatusAsync(Guid queueEntryId, string status, CancellationToken ct) =>
        throw new FakeDbException("P0002", "queue entry not found");
}
