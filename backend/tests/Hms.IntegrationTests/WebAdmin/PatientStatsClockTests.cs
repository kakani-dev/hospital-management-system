using System.Net.Http.Json;
using Hms.IntegrationTests.AuditTz;
using Hms.IntegrationTests.Sprint2;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests.WebAdmin;

/// <summary>
/// BUG-1: patient stats "registered today" follows the branch zone, not the UTC date.
/// The API clock is pinned just after Asia/Kolkata midnight (18:30 UTC). A registration
/// stamped one second earlier is yesterday; the same row stamped with the clock is today.
/// Audit stamps come from the database clock, so created_on is rewritten with triggers off.
/// The hospital is created for this test so other suites cannot change the counts.
/// </summary>
[Trait("Category", "Database")]
[Trait("Mode", "in-process-only")]
public sealed class PatientStatsClockTests(FixedClockApiFactory factory) : IClassFixture<FixedClockApiFactory>
{
    // 18:30:00 UTC is midnight in Asia/Kolkata.
    private static readonly DateTimeOffset JustBeforeIstMidnight = new(2026, 10, 9, 18, 29, 59, TimeSpan.Zero);
    private static readonly DateTimeOffset JustAfterIstMidnight = new(2026, 10, 9, 18, 30, 1, TimeSpan.Zero);

    [Fact]
    public async Task Patient_stats_count_todays_registrations_against_a_fixed_clock()
    {
        // A fresh hospital so parallel tests cannot change the counts. The API clock is the
        // first second of 10 Oct in Asia/Kolkata; both instants are still 9 Oct in UTC.
        factory.Clock.Now = JustAfterIstMidnight;
        var hospital = await ATz.NewTenantAsync(factory);
        using var admin = factory.ClientAs(hospital.AdminId, hospital.TenantId);
        var empty = (await admin.GetFromJsonAsync<PatientStats>("/api/v1/patients/stats"))!;
        Assert.Equal(0, empty.Total);
        Assert.Equal(0, empty.RegisteredToday);

        var patient = await S2.CreatePatientAsync(admin, hospital.MainBranchId);
        await StampCreatedOnAsync(patient.Id, JustBeforeIstMidnight);

        var yesterday = (await admin.GetFromJsonAsync<PatientStats>($"/api/v1/patients/stats?branchId={hospital.MainBranchId}"))!;
        Assert.Equal(1, yesterday.Total);
        Assert.Equal(0, yesterday.RegisteredToday);

        await StampCreatedOnAsync(patient.Id, JustAfterIstMidnight);
        var today = (await admin.GetFromJsonAsync<PatientStats>("/api/v1/patients/stats"))!;
        var branch = (await admin.GetFromJsonAsync<PatientStats>($"/api/v1/patients/stats?branchId={hospital.MainBranchId}"))!;
        Assert.Equal(1, today.Total);
        Assert.Equal(1, today.RegisteredToday);
        Assert.Equal(1, branch.Total);
        Assert.Equal(1, branch.RegisteredToday);
    }

    private static async Task StampCreatedOnAsync(Guid patientId, DateTimeOffset at)
    {
        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var tx = await conn.BeginTransactionAsync();
        await using (var role = new NpgsqlCommand("set local session_replication_role = replica", conn, tx))
        {
            await role.ExecuteNonQueryAsync();
        }

        await using var update = new NpgsqlCommand(
            "update patient.patients set created_on = @at, updated_on = @at where id = @id", conn, tx);
        update.Parameters.AddWithValue("at", at);
        update.Parameters.AddWithValue("id", patientId);
        Assert.Equal(1, await update.ExecuteNonQueryAsync());
        await tx.CommitAsync();
    }
}
