using Hms.Modules.Identity.Caching;
using Microsoft.Extensions.Caching.Memory;

namespace Hms.UnitTests;

public sealed class TenantReferenceCacheTests
{
    private static readonly Guid Alpha = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid Beta = Guid.Parse("22222222-2222-4222-8222-222222222222");

    private static (TenantReferenceCache Cache, ManualClock Clock) Create()
    {
        var clock = new ManualClock();
        return (new TenantReferenceCache(new MemoryCache(new MemoryCacheOptions()), clock), clock);
    }

    [Fact]
    public async Task Same_tenant_and_variant_is_served_from_cache()
    {
        var (cache, _) = Create();
        var loads = 0;
        Task<string> Load() => Task.FromResult($"alpha-{++loads}");
        Assert.Equal("alpha-1", await cache.GetOrCreateAsync(Alpha, "branches", "admin=True", Load));
        Assert.Equal("alpha-1", await cache.GetOrCreateAsync(Alpha, "branches", "admin=True", Load));
        Assert.Equal(1, loads);
    }

    [Fact]
    public async Task Another_tenant_never_sees_the_first_tenants_entry()
    {
        var (cache, _) = Create();
        Assert.Equal("alpha", await cache.GetOrCreateAsync(Alpha, "branches", "admin=True", () => Task.FromResult("alpha")));
        // identical kind and variant, different server-derived tenant id: a separate entry
        Assert.Equal("beta", await cache.GetOrCreateAsync(Beta, "branches", "admin=True", () => Task.FromResult("beta")));
        Assert.Equal("alpha", await cache.GetOrCreateAsync(Alpha, "branches", "admin=True", () => Task.FromResult("reloaded")));
        Assert.NotEqual(TenantReferenceCache.Key(Alpha, "branches", "x"), TenantReferenceCache.Key(Beta, "branches", "x"));
    }

    [Fact]
    public async Task Admin_and_member_views_are_separate_entries()
    {
        var (cache, _) = Create();
        await cache.GetOrCreateAsync(Alpha, "branches", "admin=True", () => Task.FromResult("with inactive"));
        Assert.Equal("active only", await cache.GetOrCreateAsync(Alpha, "branches", "admin=False", () => Task.FromResult("active only")));
    }

    [Fact]
    public async Task Invalidate_drops_only_that_tenant()
    {
        var (cache, _) = Create();
        await cache.GetOrCreateAsync(Alpha, "branches", "v", () => Task.FromResult("alpha-old"));
        await cache.GetOrCreateAsync(Beta, "branches", "v", () => Task.FromResult("beta-old"));
        cache.Invalidate(Alpha);
        Assert.Equal("alpha-new", await cache.GetOrCreateAsync(Alpha, "branches", "v", () => Task.FromResult("alpha-new")));
        Assert.Equal("beta-old", await cache.GetOrCreateAsync(Beta, "branches", "v", () => Task.FromResult("beta-new")));
    }

    [Fact]
    public async Task An_invalidation_during_the_read_does_not_keep_the_stale_result()
    {
        var (cache, _) = Create();
        await cache.GetOrCreateAsync(Alpha, "branches", "v", () =>
        {
            cache.Invalidate(Alpha); // a write committed while this read was running
            return Task.FromResult("stale");
        });
        Assert.Equal("fresh", await cache.GetOrCreateAsync(Alpha, "branches", "v", () => Task.FromResult("fresh")));
    }

    [Fact]
    public async Task Entries_expire_after_the_ttl()
    {
        var (cache, clock) = Create();
        // Written "one TTL ago": its absolute expiry has already passed.
        clock.Offset = -(cache.Ttl + TimeSpan.FromSeconds(1));
        await cache.GetOrCreateAsync(Alpha, "branches", "v", () => Task.FromResult("old"));
        clock.Offset = TimeSpan.Zero;
        Assert.Equal("new", await cache.GetOrCreateAsync(Alpha, "branches", "v", () => Task.FromResult("new")));
    }

    [Fact]
    public async Task No_tenant_means_no_caching()
    {
        var (cache, _) = Create();
        var loads = 0;
        await cache.GetOrCreateAsync(Guid.Empty, "branches", "v", () => Task.FromResult(++loads));
        await cache.GetOrCreateAsync(Guid.Empty, "branches", "v", () => Task.FromResult(++loads));
        Assert.Equal(2, loads);
    }

    private sealed class ManualClock : TimeProvider
    {
        public TimeSpan Offset { get; set; }

        public override DateTimeOffset GetUtcNow() => base.GetUtcNow() + Offset;
    }
}
