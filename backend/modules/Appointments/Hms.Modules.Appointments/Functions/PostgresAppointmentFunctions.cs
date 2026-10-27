using System.Data.Common;
using System.Globalization;
using Hms.Modules.Appointments.Persistence;
using Hms.SharedKernel.Persistence;

namespace Hms.Modules.Appointments.Functions;

public sealed class PostgresAppointmentFunctions(AppointmentsDbContext db) : IAppointmentFunctions
{
    public async Task<IReadOnlyList<FreeSlot>> AvailableSlotsAsync(
        Guid tenantId, Guid branchId, DateOnly fromDate, DateOnly toDate, Guid? practitionerId, int? durationMinutes, CancellationToken ct) =>
        await RawSql.QueryAsync(
            db,
            "select practitioner_id, branch_id, slot_start, slot_end from appointment.available_slots_v2(@t::uuid, @b::uuid, @f::date, @to::date, @p::uuid, @m::integer)",
            r => new FreeSlot(r.GetGuid(0), r.GetGuid(1), r.GetFieldValue<DateTimeOffset>(2), r.GetFieldValue<DateTimeOffset>(3)),
            ct,
            ("t", tenantId), ("b", branchId), ("f", fromDate), ("to", toDate), ("p", practitionerId), ("m", durationMinutes));

    public async Task<IssuedToken> CheckInAsync(Guid tenantId, Guid branchId, Guid patientId, Guid appointmentId, CancellationToken ct) =>
        (await RawSql.QueryAsync(
            db,
            "select queue_entry_id, token_no, queue_date from appointment.check_in(@t::uuid, @b::uuid, @p::uuid, @a::uuid, null::uuid)",
            Token,
            ct,
            ("t", tenantId), ("b", branchId), ("p", patientId), ("a", appointmentId))).Single();

    public async Task<IssuedToken> CheckInWalkInAsync(Guid branchId, Guid patientId, Guid? practitionerId, CancellationToken ct) =>
        (await RawSql.QueryAsync(
            db,
            "select queue_entry_id, token_no, queue_date from appointment.check_in_walk_in(@b::uuid, @p::uuid, @pr::uuid)",
            Token,
            ct,
            ("b", branchId), ("p", patientId), ("pr", practitionerId))).Single();

    public Task SetQueueStatusAsync(Guid queueEntryId, string status, CancellationToken ct) =>
        RawSql.ScalarAsync(db, "select appointment.set_queue_status(@q::uuid, @s::text)", ct, ("q", queueEntryId), ("s", status));

    public async Task<int> CloseQueueDayAsync(Guid tenantId, Guid branchId, DateOnly queueDate, CancellationToken ct)
    {
        var value = await RawSql.ScalarAsync(
            db, "select appointment.close_queue_day(@t::uuid, @b::uuid, @d::date)", ct, ("t", tenantId), ("b", branchId), ("d", queueDate));
        return Convert.ToInt32(value, CultureInfo.InvariantCulture);
    }

    public Task AssertBookableWindowAsync(Guid tenantId, Guid branchId, Guid practitionerId, DateTimeOffset startsAt, DateTimeOffset endsAt, bool overrideHours, CancellationToken ct) =>
        RawSql.ScalarAsync(db, "select appointment.assert_bookable_window_v2(@t::uuid, @b::uuid, @p::uuid, @s::timestamptz, @e::timestamptz, @o::boolean)", ct,
            ("t", tenantId), ("b", branchId), ("p", practitionerId), ("s", startsAt), ("e", endsAt), ("o", overrideHours));

    private static IssuedToken Token(DbDataReader r) => new(r.GetGuid(0), r.GetInt32(1), r.GetFieldValue<DateOnly>(2));
}
