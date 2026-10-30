using System.Collections.Concurrent;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Primitives;

namespace Hms.Modules.Identity.Caching;

/// <summary>
/// In-process cache for hot, tenant-scoped reference reads (branch list + tenant zone). Every key
/// starts with the server-derived tenant id (<c>ITenantContext.TenantId</c>, from the validated
/// token), never a client value, so one tenant can never be served another tenant's entry.
/// Entries live <see cref="Ttl"/> at most and are evicted on every write to the tenant's branches
/// or settings (<see cref="Invalidate"/>), including once more after the response (post-commit).
/// </summary>
public sealed class TenantReferenceCache(IMemoryCache cache, TimeProvider clock, IConfiguration? configuration = null)
{
    /// <summary>Fallback when <c>Caching:TenantReferenceTtlSeconds</c> is not configured.</summary>
    public const int DefaultTtlSeconds = 60;

    /// <summary>Staleness bound, from <c>Caching:TenantReferenceTtlSeconds</c> (1-3600 s).</summary>
    public TimeSpan Ttl { get; } = TimeSpan.FromSeconds(Math.Clamp(configuration?.GetValue("Caching:TenantReferenceTtlSeconds", DefaultTtlSeconds) ?? DefaultTtlSeconds, 1, 3600));

    private readonly ConcurrentDictionary<Guid, CancellationTokenSource> _tenantTokens = new();

    public static string Key(Guid tenantId, string kind, string variant) => $"ref:{tenantId:N}:{kind}:{variant}";

    public async Task<T> GetOrCreateAsync<T>(Guid tenantId, string kind, string variant, Func<Task<T>> factory)
    {
        if (tenantId == Guid.Empty)
        {
            return await factory().ConfigureAwait(false); // no tenant context: never cache
        }

        var key = Key(tenantId, kind, variant);
        if (cache.TryGetValue(key, out T? hit) && hit is not null)
        {
            return hit;
        }

        // Token captured before the read: an invalidation during the read evicts this entry at once.
        var token = _tenantTokens.GetOrAdd(tenantId, _ => new CancellationTokenSource()).Token;
        var value = await factory().ConfigureAwait(false);
        using var entry = cache.CreateEntry(key);
        entry.Value = value;
        entry.AbsoluteExpiration = clock.GetUtcNow() + Ttl;
        entry.AddExpirationToken(new CancellationChangeToken(token));
        return value;
    }

    /// <summary>Drops every cached entry of <paramref name="tenantId"/> (other tenants untouched).</summary>
    public void Invalidate(Guid tenantId)
    {
        if (_tenantTokens.TryRemove(tenantId, out var cts))
        {
            cts.Cancel();
            cts.Dispose();
        }
    }
}
