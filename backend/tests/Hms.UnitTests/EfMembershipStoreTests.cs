using Hms.Modules.Identity.Domain;
using Hms.Modules.Identity.Persistence;
using Hms.Modules.Identity.Tenancy;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;

namespace Hms.UnitTests;

public class EfMembershipStoreTests
{
    private static readonly Guid Alpha = Guid.NewGuid();
    private static readonly Guid Beta = Guid.NewGuid();
    private static readonly Guid AlphaMain = Guid.NewGuid();
    private static readonly Guid AlphaEast = Guid.NewGuid();
    private static readonly Guid Receptionist = Guid.NewGuid();
    private static readonly Guid Admin = Guid.NewGuid();

    private static IdentityDbContext Seeded(string tenantStatus = TenantStatus.Active)
    {
        var db = new IdentityDbContext(new DbContextOptionsBuilder<IdentityDbContext>().UseInMemoryDatabase(Guid.NewGuid().ToString()).Options);
        db.Tenants.AddRange(
            new Tenant { Id = Alpha, Code = "demo-alpha", Name = "Alpha", Status = tenantStatus },
            new Tenant { Id = Beta, Code = "demo-beta", Name = "Beta" });
        db.Branches.AddRange(
            new Branch { Id = AlphaMain, TenantId = Alpha, Code = "main", Name = "Main" },
            new Branch { Id = AlphaEast, TenantId = Alpha, Code = "east", Name = "East" });
        db.Memberships.AddRange(
            new Membership { TenantId = Alpha, UserId = Receptionist, BranchId = AlphaMain, Role = HmsRoles.Receptionist },
            new Membership { TenantId = Alpha, UserId = Admin, BranchId = null, Role = HmsRoles.TenantAdmin },
            new Membership { TenantId = Beta, UserId = Admin, BranchId = null, Role = HmsRoles.Viewer, Status = MembershipStatus.Suspended });
        db.SaveChanges();
        return db;
    }

    [Fact]
    public async Task Tenant_wide_membership_grants_all_branches()
    {
        var grant = await new EfMembershipStore(Seeded()).FindActiveGrantAsync(Admin, Alpha, null, default);
        Assert.NotNull(grant);
        Assert.Equal([HmsRoles.TenantAdmin], grant.Roles);
        Assert.Equal(2, grant.AccessibleBranchIds.Count);
    }

    [Fact]
    public async Task Branch_membership_is_limited_to_that_branch()
    {
        var store = new EfMembershipStore(Seeded());
        var grant = await store.FindActiveGrantAsync(Receptionist, Alpha, null, default);
        Assert.Equal([AlphaMain], grant!.AccessibleBranchIds);
        Assert.Null(await store.FindActiveGrantAsync(Receptionist, Alpha, AlphaEast, default));
    }

    [Fact]
    public async Task No_grant_for_other_tenant_suspended_membership_or_suspended_tenant()
    {
        Assert.Null(await new EfMembershipStore(Seeded()).FindActiveGrantAsync(Receptionist, Beta, null, default));
        Assert.Null(await new EfMembershipStore(Seeded()).FindActiveGrantAsync(Admin, Beta, null, default));
        Assert.Null(await new EfMembershipStore(Seeded(TenantStatus.Suspended)).FindActiveGrantAsync(Admin, Alpha, null, default));
    }
}
