using System.Collections.Concurrent;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;

namespace Hms.Modules.Billing.Caching;

/// <summary>
/// Short-lived cache of one earnings report. The key always starts with the server tenant id.
/// A per-key lock makes two simultaneous misses run the query once. A failed read is not cached.
/// An empty tenant id is never cached. Entries expire; nothing here is invalidated by a write
/// because the report is a read of committed bills and the TTL is the staleness bound.
/// </summary>
public sealed class EarningsReportCache(IMemoryCache cache, TimeProvider clock, IConfiguration? configuration = null)
{
    /// <summary>Fallback when <c>Caching:EarningsReportTtlSeconds</c> is not configured.</summary>
    public const int DefaultTtlSeconds = 45;

    /// <summary>Staleness bound, from <c>Caching:EarningsReportTtlSeconds</c> (1-3600 s).</summary>
    public TimeSpan Ttl { get; } = TimeSpan.FromSeconds(Math.Clamp(configuration?.GetValue("Caching:EarningsReportTtlSeconds", DefaultTtlSeconds) ?? DefaultTtlSeconds, 1, 3600));

    private readonly ConcurrentDictionary<string, SemaphoreSlim> _gates = new();

    public static string Key(Guid tenantId, string variant) => $"earn:{tenantId:N}:{variant}";

    public async Task<(string Json, bool Hit)> GetOrCreateAsync(
        Guid tenantId, string variant, Func<CancellationToken, Task<string>> factory, CancellationToken ct)
    {
        if (tenantId == Guid.Empty)
        {
            return (await factory(ct).ConfigureAwait(false), false);
        }

        var key = Key(tenantId, variant);
        if (TryRead(key, out var cached))
        {
            return (cached, true);
        }

        var gate = _gates.GetOrAdd(key, static _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (TryRead(key, out cached))
            {
                return (cached, true);
            }

            var json = await factory(ct).ConfigureAwait(false);
            var expiresAt = clock.GetUtcNow() + Ttl;
            cache.Set(key, new Cached(json, expiresAt.UtcTicks), new MemoryCacheEntryOptions
            {
                AbsoluteExpirationRelativeToNow = Ttl,
            });
            return (json, false);
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// Expiry follows <see cref="TimeProvider"/>, which tests can move. MemoryCache's own
    /// clock is only a backstop so an entry cannot outlive the TTL on the system clock.
    /// </summary>
    private bool TryRead(string key, out string json)
    {
        json = "";
        if (!cache.TryGetValue(key, out Cached? cached) || cached is null)
        {
            return false;
        }

        if (cached.ExpiresAtUtcTicks <= clock.GetUtcNow().UtcTicks)
        {
            return false;
        }

        json = cached.Json;
        return true;
    }

    private sealed record Cached(string Json, long ExpiresAtUtcTicks);
}
