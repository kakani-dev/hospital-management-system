using Hms.Modules.Identity.Persistence;
using Hms.Modules.Patients.Domain;
using Hms.Modules.Patients.Persistence;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;
using Npgsql;

namespace Hms.DatabaseTests;

/// <summary>
/// Connects exactly like the API does (low-privilege hms_api_login, RlsTransactionInterceptor) and
/// proves that Postgres RLS still isolates tenants when the EF query filter is bypassed or a
/// buggy/malicious context is supplied to the app layer.
/// </summary>
[Trait("Category", "Database")]
public sealed class RlsDefenseInDepthTests
{
    private static readonly string ApiConnection =
        Environment.GetEnvironmentVariable("HMS_API_TEST_CONNECTION")
        ?? "Host=localhost;Port=5432;Database=hms_sql_test;Username=hms_api_login;Password=hms_api_local_only";

    private static readonly Guid Alpha = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid Beta = Guid.Parse("22222222-2222-4222-8222-222222222222");
    private static readonly Guid AlphaMain = Guid.Parse("a1111111-0000-4000-8000-000000000001");
    private static readonly Guid BetaMain = Guid.Parse("b2222222-0000-4000-8000-000000000001");
    private static readonly Guid AlphaAdmin = Guid.Parse("0a000000-0000-4000-8000-000000000001");
    private static readonly Guid AlphaReceptionMain = Guid.Parse("0a000000-0000-4000-8000-000000000002");
    private static readonly Guid AlphaEastPatient = Guid.Parse("aa000000-0000-4000-8000-000000000003");
    private static readonly Guid BetaPatient = Guid.Parse("bb000000-0000-4000-8000-000000000001");

    private static (PatientsDbContext Db, DbSessionContext Session) PatientsAs(Guid user, Guid tenant, Guid tenantForAppFilter)
    {
        var session = new DbSessionContext();
        session.SetUser(user, null);
        session.SetTenant(tenant, null);

        // The app-layer tenant context may disagree with the DB session (simulated bug):
        var appTenant = new TenantContext();
        appTenant.Resolve(tenantForAppFilter, user, null, [HmsRoles.TenantAdmin], [AlphaMain, BetaMain]);

        var options = new DbContextOptionsBuilder<PatientsDbContext>()
            .UseNpgsql(ApiConnection)
            .UseSnakeCaseNamingConvention()
            .AddInterceptors(new RlsTransactionInterceptor(session), new TenantSaveChangesInterceptor(appTenant, TimeProvider.System))
            .Options;
        return (new PatientsDbContext(options, appTenant), session);
    }

    [Fact]
    public async Task Ignoring_the_ef_query_filter_still_returns_only_own_tenant_rows()
    {
        var (db, _) = PatientsAs(AlphaAdmin, Alpha, Alpha);
        await using var _db = db;
        await using var tx = await db.Database.BeginTransactionAsync();

        var tenants = await db.Patients.IgnoreQueryFilters().Select(p => p.TenantId).Distinct().ToListAsync();
        Assert.Equal([Alpha], tenants);
        Assert.Null(await db.Patients.IgnoreQueryFilters().SingleOrDefaultAsync(p => p.Id == BetaPatient));
        Assert.Equal(0, await db.Database.SqlQueryRaw<int>("select count(*)::int as \"Value\" from patient.patients where tenant_id = {0}", Beta).SingleAsync());
    }

    [Fact]
    public async Task App_filter_pointing_at_another_tenant_yields_nothing_because_rls_wins()
    {
        // Simulated app bug: EF filter says Beta, but the JWT/DB session is Alpha's admin.
        var (db, _) = PatientsAs(AlphaAdmin, Alpha, Beta);
        await using var _db = db;
        await using var tx = await db.Database.BeginTransactionAsync();
        Assert.Equal(0, await db.Patients.CountAsync());
    }

    [Fact]
    public async Task Forged_session_tenant_without_membership_sees_nothing()
    {
        // Even if the API resolved a tenant the user is not a member of, RLS checks memberships.
        var (db, _) = PatientsAs(AlphaAdmin, Beta, Beta);
        await using var _db = db;
        await using var tx = await db.Database.BeginTransactionAsync();
        Assert.Equal(0, await db.Patients.IgnoreQueryFilters().CountAsync());
    }

    [Fact]
    public async Task Cross_tenant_insert_is_rejected_by_rls()
    {
        // App bug stamps Beta as tenant, but the session belongs to Alpha's admin.
        var (db, _) = PatientsAs(AlphaAdmin, Alpha, Beta);
        await using var _db = db;
        await using var tx = await db.Database.BeginTransactionAsync();
        db.Patients.Add(new Patient { Mrn = $"RLS-{Guid.NewGuid():N}"[..20], FirstName = "Cross", LastName = "Insert", RegisteredBranchId = BetaMain });
        var ex = await Assert.ThrowsAsync<DbUpdateException>(() => db.SaveChangesAsync());
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, Assert.IsType<PostgresException>(ex.InnerException).SqlState);
    }

    [Fact]
    public async Task Query_outside_a_transaction_is_denied_fail_closed()
    {
        var (db, _) = PatientsAs(AlphaAdmin, Alpha, Alpha);
        await using var _db = db;
        var ex = await Assert.ThrowsAsync<PostgresException>(() => db.Patients.CountAsync());
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, ex.SqlState);
    }

    [Fact]
    public async Task Anonymous_session_has_no_access_to_tenant_data()
    {
        var session = new DbSessionContext();
        var options = new DbContextOptionsBuilder<IdentityDbContext>()
            .UseNpgsql(ApiConnection).UseSnakeCaseNamingConvention()
            .AddInterceptors(new RlsTransactionInterceptor(session)).Options;
        await using var db = new IdentityDbContext(options);
        await using var tx = await db.Database.BeginTransactionAsync();
        // anon has no USAGE on the identity/patient schemas at all.
        var ex = await Assert.ThrowsAsync<PostgresException>(() => db.Tenants.CountAsync());
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, ex.SqlState);
    }

    [Theory]
    [InlineData("service_role")]
    [InlineData("postgres")]
    [InlineData("supabase_auth_admin")]
    public async Task Api_login_cannot_escalate_to_privileged_roles(string role)
    {
        await using var conn = new NpgsqlConnection(ApiConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand($"set role {role}", conn);
        var ex = await Assert.ThrowsAsync<PostgresException>(() => cmd.ExecuteNonQueryAsync());
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, ex.SqlState);
    }

    [Fact]
    public async Task Api_login_cannot_bypass_rls_or_call_the_auth_hook()
    {
        await using var conn = new NpgsqlConnection(ApiConnection);
        await conn.OpenAsync();
        await using var tx = await conn.BeginTransactionAsync();
        await using (var setup = new NpgsqlCommand("select set_config('role','authenticated',true)", conn, tx))
        {
            await setup.ExecuteNonQueryAsync();
        }

        await using var bypass = new NpgsqlCommand("set local row_security = off; select count(*) from patient.patients", conn, tx);
        var ex = await Assert.ThrowsAsync<PostgresException>(() => bypass.ExecuteScalarAsync());
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, ex.SqlState);
    }

    [Fact]
    public async Task Api_login_cannot_execute_the_access_token_hook()
    {
        await using var conn = new NpgsqlConnection(ApiConnection);
        await conn.OpenAsync();
        await using var tx = await conn.BeginTransactionAsync();
        await using (var setup = new NpgsqlCommand("select set_config('role','authenticated',true)", conn, tx))
        {
            await setup.ExecuteNonQueryAsync();
        }

        await using var cmd = new NpgsqlCommand("select identity.custom_access_token_hook('{\"user_id\":\"0a000000-0000-4000-8000-000000000001\",\"claims\":{}}'::jsonb)", conn, tx);
        var ex = await Assert.ThrowsAsync<PostgresException>(() => cmd.ExecuteScalarAsync());
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, ex.SqlState);
    }

    [Fact]
    public async Task Branch_scoped_writer_cannot_edit_or_move_another_branchs_patient_even_bypassing_the_api()
    {
        // PR #2 review MIN-3 (PoC D4): receptionist@Main, raw UPDATE of an Alpha East patient as hms_api_login.
        // The patients UPDATE policy's row filter requires access to the CURRENT branch, so 0 rows change.
        var (db, _) = PatientsAs(AlphaReceptionMain, Alpha, Alpha);
        await using var _db = db;
        await using var tx = await db.Database.BeginTransactionAsync();

        var edited = await db.Database.ExecuteSqlRawAsync(
            "update patient.patients set first_name = 'Edited' where id = {0}", AlphaEastPatient);
        var moved = await db.Database.ExecuteSqlRawAsync(
            "update patient.patients set registered_branch_id = {0}, first_name = 'Moved' where id = {1}", AlphaMain, AlphaEastPatient);
        Assert.Equal(0, edited);
        Assert.Equal(0, moved);
        await tx.RollbackAsync();
    }
}
