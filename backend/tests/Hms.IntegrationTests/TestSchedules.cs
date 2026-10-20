using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>
/// Business rule (2026-10-20): bookings must fall inside the practitioner's working hours. Tests that
/// are about something else (overlap, queue, tenancy...) create practitioners without schedules and
/// book at arbitrary times, so the test helpers give every new practitioner round-the-clock synthetic
/// hours (00:00-23:59, every weekday, every live branch of the tenant). The rule itself is covered by
/// BusinessRulesApiTests and supabase/tests/30_business_rules_test.sql.
/// </summary>
public static class TestSchedules
{
    private const string Sql = """
        insert into appointment.schedules (tenant_id, practitioner_id, branch_id, weekday, start_time, end_time, slot_minutes, valid_from, created_by, updated_by)
        select p.tenant_id, p.id, b.id, d, '00:00', '23:59', 15, date '2020-01-01', '0a000000-0000-4000-8000-000000000001', '0a000000-0000-4000-8000-000000000001'
          from appointment.practitioners p
          join identity.branches b on b.tenant_id = p.tenant_id and not b.is_deleted
          cross join generate_series(1, 7) d
         where (@p::uuid is null or p.id = @p) and (@b::uuid is null or b.id = @b) and not p.is_deleted
           and not exists (select 1 from appointment.schedules s where s.practitioner_id = p.id and s.branch_id = b.id and s.weekday = d and not s.is_deleted)
        """;

    public static Task OpenAllHoursAsync(Guid practitionerId) => RunAsync(practitionerId, null);

    /// <summary>A branch created by a test: every practitioner of its tenant works there round the clock.</summary>
    public static Task OpenBranchAllHoursAsync(Guid branchId) => RunAsync(null, branchId);

    private static async Task RunAsync(Guid? practitionerId, Guid? branchId)
    {
        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(Sql, conn);
        cmd.Parameters.AddWithValue("p", (object?)practitionerId ?? DBNull.Value).NpgsqlDbType = NpgsqlTypes.NpgsqlDbType.Uuid;
        cmd.Parameters.AddWithValue("b", (object?)branchId ?? DBNull.Value).NpgsqlDbType = NpgsqlTypes.NpgsqlDbType.Uuid;
        await cmd.ExecuteNonQueryAsync();
    }
}
