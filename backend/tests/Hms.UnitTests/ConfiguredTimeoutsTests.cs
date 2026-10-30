using Hms.Modules.Billing.Caching;
using Hms.Modules.Identity.Caching;
using Hms.Modules.Identity.Email;
using Hms.Platform.Auth;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;

namespace Hms.UnitTests;

/// <summary>#235: cache TTLs and auth/SMTP timeouts come from configuration, with clamped fallbacks.</summary>
public sealed class ConfiguredTimeoutsTests
{
    private static IConfiguration Config(params (string Key, string Value)[] pairs) =>
        new ConfigurationBuilder().AddInMemoryCollection(pairs.Select(p => KeyValuePair.Create(p.Key, (string?)p.Value))).Build();

    private static MemoryCache Mem() => new(new MemoryCacheOptions());

    [Fact]
    public void Cache_ttls_use_configured_seconds()
    {
        var cfg = Config(("Caching:EarningsReportTtlSeconds", "7"), ("Caching:TenantReferenceTtlSeconds", "9"));
        Assert.Equal(TimeSpan.FromSeconds(7), new EarningsReportCache(Mem(), TimeProvider.System, cfg).Ttl);
        Assert.Equal(TimeSpan.FromSeconds(9), new TenantReferenceCache(Mem(), TimeProvider.System, cfg).Ttl);
    }

    [Fact]
    public void Cache_ttls_fall_back_to_defaults_when_unset()
    {
        Assert.Equal(TimeSpan.FromSeconds(EarningsReportCache.DefaultTtlSeconds), new EarningsReportCache(Mem(), TimeProvider.System, Config()).Ttl);
        Assert.Equal(TimeSpan.FromSeconds(TenantReferenceCache.DefaultTtlSeconds), new TenantReferenceCache(Mem(), TimeProvider.System).Ttl);
    }

    [Theory]
    [InlineData("0", 1)]
    [InlineData("-5", 1)]
    [InlineData("999999", 3600)]
    public void Cache_ttls_are_clamped(string configured, int expected)
    {
        var cfg = Config(("Caching:EarningsReportTtlSeconds", configured));
        Assert.Equal(TimeSpan.FromSeconds(expected), new EarningsReportCache(Mem(), TimeProvider.System, cfg).Ttl);
    }

    [Fact]
    public void Auth_and_smtp_options_bind_from_configuration()
    {
        var cfg = Config(
            ("Auth:Supabase:JwksTimeoutSeconds", "4"), ("Auth:Supabase:ClockSkewSeconds", "5"),
            ("Auth:Supabase:JwksRefreshSeconds", "6"), ("Auth:Supabase:JwksAutomaticRefreshMinutes", "7"),
            ("Smtp:TimeoutSeconds", "8"));
        var auth = cfg.GetSection(SupabaseAuthOptions.Section).Get<SupabaseAuthOptions>()!;
        Assert.Equal((4, 5, 6, 7), (auth.JwksTimeoutSeconds, auth.ClockSkewSeconds, auth.JwksRefreshSeconds, auth.JwksAutomaticRefreshMinutes));
        Assert.Equal(8, cfg.GetSection(SmtpOptions.Section).Get<SmtpOptions>()!.TimeoutSeconds);
    }

    [Fact]
    public void Auth_and_smtp_defaults_keep_previous_behaviour()
    {
        var auth = new SupabaseAuthOptions();
        Assert.Equal((10, 30, 60, 60), (auth.JwksTimeoutSeconds, auth.ClockSkewSeconds, auth.JwksRefreshSeconds, auth.JwksAutomaticRefreshMinutes));
        Assert.Equal(30, new SmtpOptions().TimeoutSeconds);
    }
}
