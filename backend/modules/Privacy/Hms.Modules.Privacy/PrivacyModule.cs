using System.Threading.RateLimiting;
using Hms.Modules.Privacy.Endpoints;
using Hms.Modules.Privacy.Persistence;
using Hms.Platform.Persistence;
using Hms.Platform.Tenancy;
using Hms.SharedKernel.Persistence;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Hms.Modules.Privacy;

public static class PrivacyModule
{
    /// <summary>Per-IP cap for the anonymous consent link. Default 30 per hour.</summary>
    public const string PublicPolicy = "hms-privacy-public";

    public static IServiceCollection AddPrivacyModule(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddHmsDbSession();
        services.AddDbContext<PrivacyDbContext>((sp, options) => options
            .UseHmsNpgsql(configuration)
            .AddInterceptors(sp.GetRequiredService<RlsTransactionInterceptor>()));
        var perHour = configuration.GetValue("RateLimiting:PrivacyPublicPerHour", 30);
        services.Configure<RateLimiterOptions>(o => o.AddPolicy(PublicPolicy, ctx => RateLimitPartition.GetFixedWindowLimiter(
            ctx.Connection.RemoteIpAddress?.ToString() ?? "anonymous",
            _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = perHour,
                Window = TimeSpan.FromHours(1),
                QueueLimit = 0,
            })));
        return services;
    }

    public static RouteGroupBuilder MapPrivacyModule(this RouteGroupBuilder api) =>
        api.MapPrivacyEndpoints();
}
