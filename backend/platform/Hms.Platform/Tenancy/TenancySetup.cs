using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Hms.Platform.Persistence;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hms.Platform.Tenancy;

public static class TenancySetup
{
    /// <summary>
    /// Per-request tenancy + DB session services for any HMS service: <see cref="TenantContext"/>,
    /// <see cref="DbSessionContext"/>, the RLS/tenant interceptors and the membership store backed by
    /// identity's published SQL surface (idempotent; modules may call <see cref="AddHmsDbSession"/> too).
    /// </summary>
    public static IServiceCollection AddHmsTenancy(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddHmsDbSession();
        services.AddHmsDatabase(configuration);
        services.TryAddScoped<TenantContext>();
        services.TryAddScoped<ITenantContext>(sp => sp.GetRequiredService<TenantContext>());
        services.TryAddScoped<IMembershipStore, NpgsqlMembershipStore>();
        return services;
    }

    /// <summary>Shared per-request DB session services (idempotent).</summary>
    public static IServiceCollection AddHmsDbSession(this IServiceCollection services)
    {
        services.TryAddScoped<DbSessionContext>();
        services.TryAddScoped<RlsTransactionInterceptor>();
        services.TryAddScoped<TenantSaveChangesInterceptor>();
        services.TryAddSingleton(TimeProvider.System);
        return services;
    }

    /// <summary>Must be placed AFTER UseAuthentication() and BEFORE UseAuthorization()/endpoints.</summary>
    public static IApplicationBuilder UseTenantResolution(this IApplicationBuilder app) =>
        app.UseMiddleware<TenantResolutionMiddleware>();
}
