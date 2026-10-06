using Hms.SharedKernel.Tenancy;

namespace Hms.UnitTests;

public class TenantContextTests
{
    private static readonly Guid Main = Guid.Parse("a1111111-0000-4000-8000-000000000001");
    private static readonly Guid East = Guid.Parse("a1111111-0000-4000-8000-000000000002");

    [Fact]
    public void Unresolved_context_fails_closed()
    {
        var ctx = new TenantContext();
        Assert.False(ctx.IsResolved);
        Assert.Throws<TenantNotResolvedException>(() => ctx.TenantId);
        Assert.False(ctx.HasAnyRole(HmsRoles.TenantAdmin));
        Assert.False(ctx.CanAccessBranch(Guid.NewGuid()));
        Assert.False(ctx.HasRoleAtBranch(Guid.NewGuid(), HmsRoles.TenantAdmin));
        Assert.Empty(ctx.RolesByBranch);
    }

    [Fact]
    public void Resolve_sets_values_and_cannot_be_called_twice()
    {
        var ctx = new TenantContext();
        var tenant = Guid.NewGuid();
        var branch = Guid.NewGuid();
        ctx.Resolve(tenant, Guid.NewGuid(), null, [HmsRoles.Receptionist], [branch]);

        Assert.Equal(tenant, ctx.TenantId);
        Assert.True(ctx.HasAnyRole(HmsRoles.Doctor, HmsRoles.Receptionist));
        Assert.False(ctx.HasAnyRole(HmsRoles.TenantAdmin));
        Assert.True(ctx.CanAccessBranch(branch));
        Assert.False(ctx.CanAccessBranch(Guid.NewGuid()));
        Assert.Throws<InvalidOperationException>(() => ctx.Resolve(Guid.NewGuid(), Guid.NewGuid(), null, [], []));
    }

    [Fact]
    public void Resolve_rejects_empty_ids()
    {
        Assert.Throws<ArgumentException>(() => new TenantContext().Resolve(Guid.Empty, Guid.NewGuid(), null, [], []));
    }

    [Fact]
    public void Roles_are_bound_to_the_branch_they_were_granted_for()
    {
        // Review M1 / PoC P2: billing at Main + nurse at East must NOT be able to write at Main.
        var ctx = new TenantContext();
        ctx.Resolve(
            Guid.NewGuid(),
            Guid.NewGuid(),
            null,
            [HmsRoles.Billing, HmsRoles.Nurse],
            [Main, East],
            new Dictionary<Guid, IReadOnlyCollection<string>> { [Main] = [HmsRoles.Billing], [East] = [HmsRoles.Nurse] });

        Assert.True(ctx.HasAnyRole(HmsRoles.Nurse)); // tenant-wide union still used for reads
        Assert.True(ctx.CanAccessBranch(Main));
        Assert.False(ctx.HasRoleAtBranch(Main, HmsRoles.Nurse, HmsRoles.Doctor, HmsRoles.Receptionist, HmsRoles.TenantAdmin));
        Assert.True(ctx.HasRoleAtBranch(Main, HmsRoles.Billing));
        Assert.True(ctx.HasRoleAtBranch(East, HmsRoles.Nurse));
        Assert.False(ctx.HasRoleAtBranch(Guid.NewGuid(), HmsRoles.Nurse, HmsRoles.Billing)); // not a branch of this tenant
    }

    [Fact]
    public void Role_map_entries_outside_accessible_branches_are_dropped()
    {
        var foreign = Guid.NewGuid();
        var ctx = new TenantContext();
        ctx.Resolve(
            Guid.NewGuid(),
            Guid.NewGuid(),
            null,
            [HmsRoles.Doctor],
            [Main],
            new Dictionary<Guid, IReadOnlyCollection<string>> { [Main] = [HmsRoles.Doctor], [foreign] = [HmsRoles.Doctor] },
            new Dictionary<Guid, string> { [Main] = "Asia/Kolkata", [foreign] = "UTC" });

        Assert.False(ctx.HasRoleAtBranch(foreign, HmsRoles.Doctor));
        Assert.Equal([Main], ctx.RolesByBranch.Keys);
        Assert.Equal([Main], ctx.BranchTimeZones.Keys);
    }
}
