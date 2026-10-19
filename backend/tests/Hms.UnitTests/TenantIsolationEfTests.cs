using Hms.Modules.Patients.Domain;
using Hms.Modules.Patients.Persistence;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;

namespace Hms.UnitTests;

/// <summary>EF-level tenant isolation (query filter + save interceptor) using two synthetic tenants.</summary>
public class TenantIsolationEfTests
{
    private static readonly Guid Alpha = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid Beta = Guid.Parse("22222222-2222-4222-8222-222222222222");
    private static readonly Guid AlphaBranch = Guid.Parse("a1111111-0000-4000-8000-000000000001");
    private static readonly Guid BetaBranch = Guid.Parse("b2222222-0000-4000-8000-000000000001");

    private readonly string _dbName = Guid.NewGuid().ToString();

    private PatientsDbContext Create(TenantContext tenant) =>
        new(new DbContextOptionsBuilder<PatientsDbContext>()
                .UseInMemoryDatabase(_dbName)
                .AddInterceptors(new TenantSaveChangesInterceptor(tenant, TimeProvider.System))
                .Options,
            tenant);

    private static TenantContext As(Guid tenantId, Guid branchId)
    {
        var ctx = new TenantContext();
        ctx.Resolve(tenantId, Guid.NewGuid(), null, [HmsRoles.TenantAdmin], [branchId]);
        return ctx;
    }

    private async Task SeedAsync()
    {
        await using (var alpha = Create(As(Alpha, AlphaBranch)))
        {
            alpha.Patients.Add(new Patient { Mrn = "MRN-1001", FirstName = "Kiran", LastName = "Synthetic-Alpha", RegisteredBranchId = AlphaBranch });
            alpha.Patients.Add(new Patient { Mrn = "ALP-0001", FirstName = "Asha", LastName = "Synthetic-Alpha", RegisteredBranchId = AlphaBranch });
            await alpha.SaveChangesAsync();
        }

        await using var beta = Create(As(Beta, BetaBranch));
        beta.Patients.Add(new Patient { Mrn = "MRN-1001", FirstName = "Kiran", LastName = "Synthetic-Beta", RegisteredBranchId = BetaBranch });
        await beta.SaveChangesAsync();
    }

    [Fact]
    public async Task Each_tenant_only_sees_its_own_patients()
    {
        await SeedAsync();

        await using var alpha = Create(As(Alpha, AlphaBranch));
        var alphaRows = await alpha.Patients.ToListAsync();
        Assert.Equal(2, alphaRows.Count);
        Assert.All(alphaRows, p => Assert.Equal(Alpha, p.TenantId));

        await using var beta = Create(As(Beta, BetaBranch));
        Assert.Single(await beta.Patients.ToListAsync());
    }

    [Fact]
    public async Task Unresolved_tenant_sees_nothing()
    {
        await SeedAsync();
        await using var db = Create(new TenantContext());
        Assert.Empty(await db.Patients.ToListAsync());
    }

    [Fact]
    public async Task Client_supplied_tenant_id_is_overwritten_on_insert()
    {
        await using (var alpha = Create(As(Alpha, AlphaBranch)))
        {
            alpha.Patients.Add(new Patient { TenantId = Beta, Mrn = "EVIL-1", FirstName = "Evil", LastName = "Insert", RegisteredBranchId = AlphaBranch });
            await alpha.SaveChangesAsync();
        }

        await using var beta = Create(As(Beta, BetaBranch));
        Assert.Empty(await beta.Patients.ToListAsync());
        await using var alphaAgain = Create(As(Alpha, AlphaBranch));
        Assert.Equal(Alpha, (await alphaAgain.Patients.SingleAsync()).TenantId);
    }

    [Fact]
    public async Task Changing_tenant_id_is_blocked()
    {
        await SeedAsync();
        await using var alpha = Create(As(Alpha, AlphaBranch));
        var patient = await alpha.Patients.FirstAsync();
        patient.TenantId = Beta;
        await Assert.ThrowsAsync<InvalidOperationException>(() => alpha.SaveChangesAsync());
    }

    [Fact]
    public async Task Writing_without_a_resolved_tenant_throws()
    {
        await using var db = Create(new TenantContext());
        db.Patients.Add(new Patient { Mrn = "X-1", FirstName = "No", LastName = "Tenant", RegisteredBranchId = AlphaBranch });
        await Assert.ThrowsAsync<TenantNotResolvedException>(() => db.SaveChangesAsync());
    }

    [Fact]
    public async Task Soft_deleted_patients_are_hidden()
    {
        await SeedAsync();
        await using (var alpha = Create(As(Alpha, AlphaBranch)))
        {
            var p = await alpha.Patients.FirstAsync(x => x.Mrn == "ALP-0001");
            p.DeletedAt = DateTimeOffset.UtcNow;
            p.IsDeleted = true; // generated column in PostgreSQL
            await alpha.SaveChangesAsync();
        }

        await using var check = Create(As(Alpha, AlphaBranch));
        Assert.Single(await check.Patients.ToListAsync());
    }
}
