using Hms.Modules.Patients.Domain;
using Hms.Modules.Patients.Persistence;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;

namespace Hms.DatabaseTests;

/// <summary>
/// Level 1: MRNs come from the per-tenant counter (patient.assign_mrn trigger). Many API-style
/// connections inserting at the same moment must get distinct, gap-free numbers, and EF must read
/// the generated MRN back from INSERT ... RETURNING.
/// </summary>
[Trait("Category", "Database")]
public sealed class MrnConcurrencyTests
{
    private static readonly string ApiConnection =
        Environment.GetEnvironmentVariable("HMS_API_TEST_CONNECTION")
        ?? "Host=localhost;Port=5432;Database=hms_sql_test;Username=hms_api_login;Password=hms_api_local_only";

    private static readonly Guid Alpha = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid AlphaMain = Guid.Parse("a1111111-0000-4000-8000-000000000001");
    private static readonly Guid AlphaReceptionMain = Guid.Parse("0a000000-0000-4000-8000-000000000002");

    private static PatientsDbContext NewContext()
    {
        var session = new DbSessionContext();
        session.SetUser(AlphaReceptionMain, null);
        session.SetTenant(Alpha, null);
        var tenant = new TenantContext();
        tenant.Resolve(Alpha, AlphaReceptionMain, null, [HmsRoles.Receptionist], [AlphaMain]);
        var options = new DbContextOptionsBuilder<PatientsDbContext>()
            .UseNpgsql(ApiConnection)
            .UseSnakeCaseNamingConvention()
            .AddInterceptors(new RlsTransactionInterceptor(session), new TenantSaveChangesInterceptor(tenant, TimeProvider.System))
            .Options;
        return new PatientsDbContext(options, tenant);
    }

    [Fact]
    public async Task Parallel_inserts_in_one_tenant_get_distinct_consecutive_mrns()
    {
        const int n = 24;
        using var start = new ManualResetEventSlim(false);
        var tasks = Enumerable.Range(0, n).Select(i => Task.Run(async () =>
        {
            await using var db = NewContext();
            await using var tx = await db.Database.BeginTransactionAsync();
            var patient = new Patient { FirstName = "Parallel", LastName = $"Mrn-{i}", RegisteredBranchId = AlphaMain };
            db.Patients.Add(patient);
            start.Wait();
            await db.SaveChangesAsync();
            await tx.CommitAsync();
            return patient.Mrn;
        })).ToArray();

        start.Set();
        var mrns = await Task.WhenAll(tasks);

        Assert.All(mrns, m => Assert.Matches("^DEMO-ALPHA-[0-9]{6,}$", m));
        Assert.Equal(n, mrns.Distinct(StringComparer.Ordinal).Count());
        var numbers = mrns.Select(m => long.Parse(m["DEMO-ALPHA-".Length..], System.Globalization.CultureInfo.InvariantCulture)).Order().ToArray();
        Assert.Equal(numbers[0] + n - 1, numbers[^1]); // no gaps among committed inserts
    }

    [Fact]
    public async Task A_client_supplied_mrn_is_never_sent_and_the_generated_one_is_read_back()
    {
        await using var db = NewContext();
        await using var tx = await db.Database.BeginTransactionAsync();
        var patient = new Patient { Mrn = "TYPED-BY-USER", FirstName = "Typed", LastName = "Mrn", RegisteredBranchId = AlphaMain };
        db.Patients.Add(patient);
        await db.SaveChangesAsync();
        Assert.StartsWith("DEMO-ALPHA-", patient.Mrn, StringComparison.Ordinal);
        Assert.Equal(patient.Mrn, await db.Patients.Where(p => p.Id == patient.Id).Select(p => p.Mrn).SingleAsync());
    }
}
