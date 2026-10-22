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
    private const string MembershipSql = """
        insert into appointment.practitioner_branches (tenant_id, practitioner_id, branch_id, is_active)
        select p.tenant_id, p.id, @b, true
          from appointment.practitioners p
         where p.id = @p
           and exists (select 1 from identity.branches b where b.id = @b and b.tenant_id = p.tenant_id)
           and not exists (
             select 1 from appointment.practitioner_branches m
              where m.tenant_id = p.tenant_id and m.practitioner_id = p.id and m.branch_id = @b and not m.is_deleted)
        """;

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
        // Concurrent bookings of one practitioner/day insert the same schedule. The exclusion constraint
        // usually answers 23P01; under overlap it deadlocks (40P01) and rolls the victim back. Retry the
        // victim so the winner's row is visible and the booking can proceed.
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                try
                {
                    await using var member = new NpgsqlCommand(MembershipSql, conn);
                    member.Parameters.AddWithValue("b", branchId);
                    member.Parameters.AddWithValue("p", practitionerId);
                    await member.ExecuteNonQueryAsync();
                }
                catch (PostgresException ex) when (ex.SqlState is "23505")
                {
                    // Another booking inserted the same membership first.
                }

                await using var cmd = new NpgsqlCommand(Sql, conn);
                cmd.Parameters.AddWithValue("b", branchId);
                cmd.Parameters.AddWithValue("p", practitionerId);
                cmd.Parameters.AddWithValue("s", start.ToUniversalTime());
                await cmd.ExecuteNonQueryAsync();
                return;
            }
            catch (PostgresException ex) when (ex.SqlState is "23P01" or "23505")
            {
                return;
            }
            catch (PostgresException ex) when (ex.SqlState is "40P01" && attempt < 4)
            {
                // loser of the deadlock; try again
            }
        }
    }
}
