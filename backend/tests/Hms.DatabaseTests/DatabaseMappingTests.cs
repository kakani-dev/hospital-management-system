using Hms.Modules.Identity.Persistence;
using Hms.Modules.Identity.Tenancy;
using Hms.Modules.Patients.Domain;
using Hms.Modules.Patients.Persistence;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;
using Npgsql;

namespace Hms.DatabaseTests;

/// <summary>
/// Runs the EF Core model against the REAL PostgreSQL schema produced by supabase/migrations + seed.sql.
/// Requires a database prepared by supabase/scripts/run-sql-tests.sh (default: hms_sql_test on localhost).
/// These tests FAIL (not skip) when the database is unavailable, so they are excluded from the
/// default CI unit job via --filter "Category!=Database" and run in the SQL job instead.
/// </summary>
[Trait("Category", "Database")]
public sealed class DatabaseMappingTests
{
    private static readonly string ConnectionString =
        Environment.GetEnvironmentVariable("HMS_DB_TEST_CONNECTION")
        ?? "Host=localhost;Port=5432;Database=hms_sql_test;Username=postgres;Password=postgres";

    private static readonly Guid Alpha = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid Beta = Guid.Parse("22222222-2222-4222-8222-222222222222");
    private static readonly Guid AlphaMain = Guid.Parse("a1111111-0000-4000-8000-000000000001");
    private static readonly Guid AlphaAdmin = Guid.Parse("0a000000-0000-4000-8000-000000000001");
    private static readonly Guid AlphaReception = Guid.Parse("0a000000-0000-4000-8000-000000000002");
    private static readonly Guid Outsider = Guid.Parse("0c000000-0000-4000-8000-000000000001");

    private static IdentityDbContext Identity() =>
        new(new DbContextOptionsBuilder<IdentityDbContext>().UseNpgsql(ConnectionString).UseSnakeCaseNamingConvention().Options);

    private static PatientsDbContext Patients(TenantContext tenant) =>
        new(new DbContextOptionsBuilder<PatientsDbContext>()
                .UseNpgsql(ConnectionString)
                .UseSnakeCaseNamingConvention()
                .AddInterceptors(new TenantSaveChangesInterceptor(tenant, TimeProvider.System))
                .Options,
            tenant);

    private static TenantContext As(Guid tenantId, Guid userId, params Guid[] branches)
    {
        var ctx = new TenantContext();
        ctx.Resolve(tenantId, userId, null, [HmsRoles.TenantAdmin], branches);
        return ctx;
    }

    [Fact]
    public async Task Ef_model_matches_sql_schema_for_every_mapped_table()
    {
        await using var identity = Identity();
        // Seed-relative (other suites add branches/memberships/patients to the same database).
        Assert.True(await identity.Tenants.CountAsync() >= 2);
        Assert.True(await identity.Branches.CountAsync() >= 3);
        Assert.True(await identity.Memberships.CountAsync() >= 7);
        await using var patients = Patients(As(Alpha, AlphaAdmin, AlphaMain));
        Assert.NotNull(await patients.Patients.FirstAsync());
    }

    [Fact]
    public async Task Query_filter_isolates_seeded_tenants()
    {
        await using var alpha = Patients(As(Alpha, AlphaAdmin, AlphaMain));
        Assert.Equal(4, await alpha.Patients.CountAsync(p => p.LastName == "Synthetic-Alpha"));
        Assert.Equal(0, await alpha.Patients.CountAsync(p => p.LastName == "Synthetic-Beta"));
        Assert.Equal(1, await alpha.Patients.CountAsync(p => p.Mrn == "MRN-1001"));

        await using var beta = Patients(As(Beta, Guid.NewGuid()));
        Assert.Equal(3, await beta.Patients.CountAsync(p => p.LastName == "Synthetic-Beta"));
        Assert.DoesNotContain(await beta.Patients.Select(p => p.TenantId).Distinct().ToListAsync(), t => t == Alpha);
    }

    [Fact]
    public async Task Membership_store_reads_real_memberships()
    {
        await using var identity = Identity();
        var store = new EfMembershipStore(identity);

        var admin = await store.FindActiveGrantAsync(AlphaAdmin, Alpha, null, default);
        // >= : the API integration tests run in parallel against the same database and may add Alpha branches.
        Assert.True(admin!.AccessibleBranchIds.Count >= 2);

        var reception = await store.FindActiveGrantAsync(AlphaReception, Alpha, null, default);
        Assert.Equal([AlphaMain], reception!.AccessibleBranchIds);

        Assert.Null(await store.FindActiveGrantAsync(Outsider, Alpha, null, default));
        Assert.Null(await store.FindActiveGrantAsync(AlphaAdmin, Beta, null, default));
    }

    [Fact]
    public async Task Insert_through_ef_is_tenant_stamped_and_audited_by_database_trigger()
    {
        await using var db = Patients(As(Alpha, AlphaAdmin, AlphaMain));
        await using var tx = await db.Database.BeginTransactionAsync();

        var patient = new Patient { TenantId = Beta, Mrn = "DBT-0001", FirstName = "Ef", LastName = "Synthetic-Alpha", RegisteredBranchId = AlphaMain };
        db.Patients.Add(patient);
        await db.SaveChangesAsync();

        var conn = (NpgsqlConnection)db.Database.GetDbConnection();
        await using (var cmd = new NpgsqlCommand("select tenant_id from patient.patients where id = @id", conn))
        {
            cmd.Parameters.AddWithValue("id", patient.Id);
            Assert.Equal(Alpha, (Guid)(await cmd.ExecuteScalarAsync())!);
        }

        await using (var cmd = new NpgsqlCommand("select count(*) from audit.audit_log where record_id = @id and tenant_id = @t and action = 'INSERT'", conn))
        {
            cmd.Parameters.AddWithValue("id", patient.Id);
            cmd.Parameters.AddWithValue("t", Alpha);
            Assert.Equal(1L, (long)(await cmd.ExecuteScalarAsync())!);
        }

        await tx.RollbackAsync();
    }

    [Fact]
    public async Task Database_rejects_duplicate_mrn_within_tenant()
    {
        await using var db = Patients(As(Alpha, AlphaAdmin, AlphaMain));
        await using var tx = await db.Database.BeginTransactionAsync();
        db.Patients.Add(new Patient { Mrn = "ALP-0001", FirstName = "Dup", LastName = "Synthetic-Alpha", RegisteredBranchId = AlphaMain });
        var ex = await Assert.ThrowsAsync<DbUpdateException>(() => db.SaveChangesAsync());
        Assert.Equal(PostgresErrorCodes.UniqueViolation, Assert.IsType<PostgresException>(ex.InnerException).SqlState);
        await tx.RollbackAsync();
    }
}
