using System.Security.Claims;
using Hms.Modules.Identity.Tenancy;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging.Abstractions;

namespace Hms.UnitTests;

public class TenantResolutionMiddlewareTests
{
    private static readonly Guid User = Guid.Parse("0d000000-0000-4000-8000-000000000001");
    private static readonly Guid Alpha = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid Beta = Guid.Parse("22222222-2222-4222-8222-222222222222");
    private static readonly Guid AlphaEast = Guid.Parse("a1111111-0000-4000-8000-000000000002");

    private sealed class FakeStore(ActiveContext? fallback, params (Guid Tenant, string Role)[] grants) : IMembershipStore
    {
        public int DefaultLookups { get; private set; }

        public Task<MembershipGrant?> FindActiveGrantAsync(Guid userId, Guid tenantId, Guid? branchId, CancellationToken cancellationToken)
        {
            var roles = grants.Where(g => g.Tenant == tenantId).Select(g => g.Role).ToList();
            return Task.FromResult(roles.Count == 0 ? null : new MembershipGrant(roles, [AlphaEast]));
        }

        public Task<ActiveContext?> FindDefaultContextAsync(CancellationToken cancellationToken)
        {
            DefaultLookups++;
            return Task.FromResult(fallback);
        }
    }

    private static async Task<(TenantContext Tenant, DbSessionContext Session, bool NextCalled)> Run(FakeStore store, params (string, string)[] claims)
    {
        var http = new DefaultHttpContext
        {
            User = new ClaimsPrincipal(new ClaimsIdentity(claims.Select(c => new Claim(c.Item1, c.Item2)), "Bearer")),
        };
        var called = false;
        var middleware = new TenantResolutionMiddleware(_ => { called = true; return Task.CompletedTask; }, NullLogger<TenantResolutionMiddleware>.Instance);
        var tenant = new TenantContext();
        var session = new DbSessionContext();
        await middleware.InvokeAsync(http, tenant, session, store);
        return (tenant, session, called);
    }

    [Fact]
    public async Task Tenant_claim_with_membership_resolves_and_pins_db_session()
    {
        var (tenant, session, next) = await Run(new FakeStore(null, (Alpha, HmsRoles.Doctor)), ("sub", User.ToString()), ("tenant_id", Alpha.ToString()));
        Assert.True(next);
        Assert.True(tenant.IsResolved);
        Assert.Equal(Alpha, session.TenantId);
        Assert.Equal(User, session.UserId);
    }

    [Fact]
    public async Task Tenant_claim_without_membership_leaves_context_unresolved_but_user_set()
    {
        var store = new FakeStore(new ActiveContext(Alpha, null), (Alpha, HmsRoles.Doctor));
        var (tenant, session, next) = await Run(store, ("sub", User.ToString()), ("tenant_id", Beta.ToString()));
        Assert.True(next);
        Assert.False(tenant.IsResolved);
        Assert.Null(session.TenantId);
        Assert.Equal(User, session.UserId);
        Assert.Equal(0, store.DefaultLookups); // a present-but-invalid claim never falls back
    }

    [Fact]
    public async Task Missing_tenant_claim_uses_server_side_default()
    {
        var store = new FakeStore(new ActiveContext(Beta, null), (Beta, HmsRoles.Doctor));
        var (tenant, session, _) = await Run(store, ("sub", User.ToString()));
        Assert.Equal(1, store.DefaultLookups);
        Assert.True(tenant.IsResolved);
        Assert.Equal(Beta, session.TenantId);
    }

    [Fact]
    public async Task Missing_tenant_claim_and_no_memberships_stays_unresolved()
    {
        var (tenant, session, next) = await Run(new FakeStore(null), ("sub", User.ToString()));
        Assert.True(next);
        Assert.False(tenant.IsResolved);
        Assert.Null(session.TenantId);
    }

    [Fact]
    public async Task Unauthenticated_request_passes_through_as_anon()
    {
        var http = new DefaultHttpContext();
        var session = new DbSessionContext();
        var called = false;
        var middleware = new TenantResolutionMiddleware(_ => { called = true; return Task.CompletedTask; }, NullLogger<TenantResolutionMiddleware>.Instance);
        await middleware.InvokeAsync(http, new TenantContext(), session, new FakeStore(null));
        Assert.True(called);
        Assert.False(session.IsAuthenticated);
    }
}
