using Hms.SharedKernel.Tenancy;

namespace Hms.UnitTests;

public class TenantContextTests
{
    [Fact]
    public void Unresolved_context_fails_closed()
    {
        var ctx = new TenantContext();
        Assert.False(ctx.IsResolved);
        Assert.Throws<TenantNotResolvedException>(() => ctx.TenantId);
        Assert.False(ctx.HasAnyRole(HmsRoles.TenantAdmin));
        Assert.False(ctx.CanAccessBranch(Guid.NewGuid()));
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
}
