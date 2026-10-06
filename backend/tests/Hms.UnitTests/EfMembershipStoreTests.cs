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
    private static readonly Guid MixedRoles = Guid.NewGuid();
    private static readonly Guid Invitee = Guid.NewGuid();

    private static IdentityDbContext Seeded(string tenantStatus = TenantStatus.Active)
    {
        var db = new IdentityDbContext(new DbContextOptionsBuilder<IdentityDbContext>().UseInMemoryDatabase(Guid.NewGuid().ToString()).Options);
        db.Tenants.AddRange(
            new Tenant { Id = Alpha, Code = "demo-alpha", Name = "Alpha", Status = tenantStatus },
            new Tenant { Id = Beta, Code = "demo-beta", Name = "Beta" });
        db.Branches.AddRange(
            new Branch { Id = AlphaMain, TenantId = Alpha, Code = "main", Name = "Main" },
            new Branch { Id = AlphaEast, TenantId = Alpha, Code = "east", Name = "East", Timezone = "Asia/Dubai" });
        db.Memberships.AddRange(
            new Membership { TenantId = Alpha, UserId = Receptionist, BranchId = AlphaMain, Role = HmsRoles.Receptionist },
            new Membership { TenantId = Alpha, UserId = Admin, BranchId = null, Role = HmsRoles.TenantAdmin },
            new Membership { TenantId = Beta, UserId = Admin, BranchId = null, Role = HmsRoles.Viewer, Status = MembershipStatus.Suspended },
            // PoC P2: billing at Main, nurse at East.
            new Membership { TenantId = Alpha, UserId = MixedRoles, BranchId = AlphaMain, Role = HmsRoles.Billing },
            new Membership { TenantId = Alpha, UserId = MixedRoles, BranchId = AlphaEast, Role = HmsRoles.Nurse },
            new Membership { TenantId = Alpha, UserId = Invitee, BranchId = null, Role = HmsRoles.Doctor, Status = MembershipStatus.Invited });
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

    [Fact]
    public async Task Role_map_binds_each_role_to_its_branch()
    {
        var grant = await new EfMembershipStore(Seeded()).FindActiveGrantAsync(MixedRoles, Alpha, null, default);
        Assert.NotNull(grant);
        Assert.Equal([HmsRoles.Billing], grant.RolesByBranch[AlphaMain]);
        Assert.Equal([HmsRoles.Nurse], grant.RolesByBranch[AlphaEast]);
        Assert.Equal(2, grant.AccessibleBranchIds.Count);
        Assert.Equal("Asia/Kolkata", grant.BranchTimeZones[AlphaMain]);
        Assert.Equal("Asia/Dubai", grant.BranchTimeZones[AlphaEast]);
    }

    [Fact]
    public async Task Tenant_wide_roles_apply_at_every_branch()
    {
        var grant = await new EfMembershipStore(Seeded()).FindActiveGrantAsync(Admin, Alpha, null, default);
        Assert.Equal([HmsRoles.TenantAdmin], grant!.RolesByBranch[AlphaMain]);
        Assert.Equal([HmsRoles.TenantAdmin], grant.RolesByBranch[AlphaEast]);
    }

    [Fact]
    public async Task Branch_only_member_has_no_role_map_entry_for_other_branches()
    {
        var grant = await new EfMembershipStore(Seeded()).FindActiveGrantAsync(Receptionist, Alpha, null, default);
        Assert.False(grant!.RolesByBranch.ContainsKey(AlphaEast));
        Assert.False(grant.BranchTimeZones.ContainsKey(AlphaEast));
    }

    [Fact]
    public async Task Invited_membership_grants_nothing() =>
        Assert.Null(await new EfMembershipStore(Seeded()).FindActiveGrantAsync(Invitee, Alpha, null, default));
}
