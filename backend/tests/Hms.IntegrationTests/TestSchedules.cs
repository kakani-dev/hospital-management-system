using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>
/// Business rule (2026-10-20): bookings must fall inside the practitioner's working hours. Tests about
/// other things (overlap, queue, tenancy...) book practitioners without schedules at arbitrary times,
/// so the booking helpers first open a synthetic one-day schedule (00:00-23:59 on that branch-local
/// date only) unless the practitioner already has hours that day. The rule itself is covered by
/// BusinessRulesApiTests and supabase/tests/30_business_rules_test.sql.
/// </summary>
public static class TestSchedules
{
    private const string Sql = """
        with d as (
          select (@s::timestamptz at time zone identity.branch_time_zone_v1(@b))::date as day)
        insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from, valid_to, created_by, updated_by)
        select p.tenant_id, p.id, @b, extract(isodow from d.day)::smallint, '00:00', '23:59', 15, d.day, d.day,
               '0a000000-0000-4000-8000-000000000001', '0a000000-0000-4000-8000-000000000001'
          from appointment.practitioners p cross join d
         where p.id = @p
           and exists (select 1 from identity.branches b where b.id = @b and b.tenant_id = p.tenant_id)
           and not exists (select 1 from appointment.schedules s
                            where s.practitioner_id = p.id and s.is_active and not s.is_deleted
                              and s.weekday = extract(isodow from d.day)
                              and s.valid_from <= d.day and (s.valid_to is null or s.valid_to >= d.day))
        """;

    public static async Task OpenDayAsync(Guid branchId, Guid practitionerId, DateTimeOffset start)
    {
        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(Sql, conn);
        cmd.Parameters.AddWithValue("b", branchId);
        cmd.Parameters.AddWithValue("p", practitionerId);
        cmd.Parameters.AddWithValue("s", start.ToUniversalTime());
        try
        {
            await cmd.ExecuteNonQueryAsync();
        }
        catch (PostgresException ex) when (ex.SqlState is "23P01" or "23505")
        {
            // a concurrent helper call opened the same day first
        }
    }
}
