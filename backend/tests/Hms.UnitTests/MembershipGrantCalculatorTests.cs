using Hms.Platform.Tenancy;
using Hms.SharedKernel.Tenancy;

namespace Hms.UnitTests;

/// <summary>
/// Same scenarios as the Sprint 1 EfMembershipStore tests, now on the pure calculator that every
/// service uses (the DB part, identity.my_tenant_grant_v1, is covered by the SQL tests and
/// Hms.DatabaseTests against real Postgres).
/// </summary>
public class MembershipGrantCalculatorTests
{
    private static readonly Guid AlphaMain = Guid.NewGuid();
    private static readonly Guid AlphaEast = Guid.NewGuid();

    // Active branches of Alpha (the function only returns active ones of an active tenant).
    private static readonly BranchRow[] AlphaBranches = [new(AlphaMain, null), new(AlphaEast, "Asia/Dubai")];

    private static readonly MembershipRow[] Receptionist = [new(HmsRoles.Receptionist, AlphaMain)];
    private static readonly MembershipRow[] Admin = [new(HmsRoles.TenantAdmin, null)];

    // PoC P2: billing at Main, nurse at East.
    private static readonly MembershipRow[] MixedRoles = [new(HmsRoles.Billing, AlphaMain), new(HmsRoles.Nurse, AlphaEast)];

    [Fact]
    public void Tenant_wide_membership_grants_all_branches()
    {
        var grant = MembershipGrantCalculator.Compute(Admin, AlphaBranches, null, "Asia/Kolkata");
        Assert.NotNull(grant);
        Assert.Equal([HmsRoles.TenantAdmin], grant.Roles);
        Assert.Equal(2, grant.AccessibleBranchIds.Count);
    }

    [Fact]
    public void Branch_membership_is_limited_to_that_branch()
    {
        var grant = MembershipGrantCalculator.Compute(Receptionist, AlphaBranches, null, "Asia/Kolkata");
        Assert.Equal([AlphaMain], grant!.AccessibleBranchIds);
        Assert.Null(MembershipGrantCalculator.Compute(Receptionist, AlphaBranches, AlphaEast, "Asia/Kolkata"));
    }

    [Fact]
    public void No_active_membership_means_no_grant() =>
        // Other tenant / suspended or invited membership / suspended tenant: the DB returns no rows (or null).
        Assert.Null(MembershipGrantCalculator.Compute([], AlphaBranches, null, "Asia/Kolkata"));

    [Fact]
    public void Role_map_binds_each_role_to_its_branch()
    {
        var grant = MembershipGrantCalculator.Compute(MixedRoles, AlphaBranches, null, "Asia/Kolkata");
        Assert.NotNull(grant);
        Assert.Equal([HmsRoles.Billing], grant.RolesByBranch[AlphaMain]);
        Assert.Equal([HmsRoles.Nurse], grant.RolesByBranch[AlphaEast]);
        Assert.Equal(2, grant.AccessibleBranchIds.Count);
        Assert.Equal("Asia/Kolkata", grant.BranchTimeZones[AlphaMain]);
        Assert.Equal("Asia/Dubai", grant.BranchTimeZones[AlphaEast]);
    }

    [Fact]
    public void Pinned_branch_only_keeps_roles_valid_there()
    {
        var grant = MembershipGrantCalculator.Compute(MixedRoles, AlphaBranches, AlphaEast, "Asia/Kolkata");
        Assert.Equal([HmsRoles.Nurse], grant!.Roles);
    }

    [Fact]
    public void Tenant_wide_roles_apply_at_every_branch()
    {
        var grant = MembershipGrantCalculator.Compute(Admin, AlphaBranches, null, "Asia/Kolkata");
        Assert.Equal([HmsRoles.TenantAdmin], grant!.RolesByBranch[AlphaMain]);
        Assert.Equal([HmsRoles.TenantAdmin], grant.RolesByBranch[AlphaEast]);
    }

    [Fact]
    public void Branch_only_member_has_no_role_map_entry_for_other_branches()
    {
        var grant = MembershipGrantCalculator.Compute(Receptionist, AlphaBranches, null, "Asia/Kolkata");
        Assert.False(grant!.RolesByBranch.ContainsKey(AlphaEast));
        Assert.False(grant.BranchTimeZones.ContainsKey(AlphaEast));
    }

    [Fact]
    public void Store_parses_the_published_grant_document()
    {
        var json = $$"""
            {"tenant_time_zone":"Asia/Kolkata","memberships":[{"role":"billing","branch_id":"{{AlphaMain}}"},{"role":"nurse","branch_id":"{{AlphaEast}}"}],
             "branches":[{"id":"{{AlphaMain}}","timezone":"Asia/Kolkata"},{"id":"{{AlphaEast}}","timezone":"Asia/Dubai"}]}
            """;
        var grant = NpgsqlMembershipStore.Parse(json, null);
        Assert.Equal([HmsRoles.Billing], grant!.RolesByBranch[AlphaMain]);
        Assert.Equal("Asia/Dubai", grant.BranchTimeZones[AlphaEast]);

        var tenantWide = NpgsqlMembershipStore.Parse("""{"tenant_time_zone":"Europe/London","memberships":[{"role":"tenant_admin","branch_id":null}],"branches":[]}""", null);
        Assert.Equal([HmsRoles.TenantAdmin], tenantWide!.Roles);
        Assert.Empty(tenantWide.AccessibleBranchIds);

        Assert.Null(NpgsqlMembershipStore.Parse("""{"tenant_time_zone":"UTC","memberships":[],"branches":[]}""", null));
        Assert.Equal("Europe/London", tenantWide.TenantTimeZone);
        Assert.Throws<Hms.SharedKernel.Time.MissingTimeZoneException>(
            () => NpgsqlMembershipStore.Parse("""{"memberships":[{"role":"tenant_admin","branch_id":null}],"branches":[]}""", null));
    }

    [Fact]
    public void Branch_without_override_inherits_the_tenant_zone()
    {
        var grant = MembershipGrantCalculator.Compute(Admin, AlphaBranches, null, "Asia/Kolkata")!;
        Assert.Equal("Asia/Kolkata", grant.TenantTimeZone);
        Assert.Equal("Asia/Kolkata", grant.BranchTimeZones[AlphaMain]); // no override
        Assert.Equal("Asia/Dubai", grant.BranchTimeZones[AlphaEast]);   // override wins
    }
}
