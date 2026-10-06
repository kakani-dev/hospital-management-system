using Hms.Modules.Identity.Endpoints;
using Hms.Modules.Identity.Persistence;
using Hms.Modules.Identity.Tenancy;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hms.Modules.Identity;

public static class IdentityModule
{
    public static IServiceCollection AddIdentityModule(this IServiceCollection services, IConfiguration configuration)
    {
        var connectionString = configuration.GetConnectionString("HmsDatabase");
        services.AddHmsDbSession();
        services.AddDbContext<IdentityDbContext>((sp, options) => options
            .UseNpgsql(connectionString)
            .UseSnakeCaseNamingConvention()
            .AddInterceptors(
                sp.GetRequiredService<RlsTransactionInterceptor>(),
                sp.GetRequiredService<TenantSaveChangesInterceptor>()));

        services.AddScoped<TenantContext>();
        services.AddScoped<ITenantContext>(sp => sp.GetRequiredService<TenantContext>());
        services.AddScoped<IMembershipStore, EfMembershipStore>();
        return services;
    }

    /// <summary>Shared per-request DB session services (idempotent; other modules call it too).</summary>
    public static IServiceCollection AddHmsDbSession(this IServiceCollection services)
    {
        services.TryAddScoped<DbSessionContext>();
        services.TryAddScoped<RlsTransactionInterceptor>();
        services.TryAddScoped<TenantSaveChangesInterceptor>();
        services.TryAddSingleton(TimeProvider.System);
        return services;
    }

    public static RouteGroupBuilder MapIdentityEndpoints(this RouteGroupBuilder api) =>
        api.MapMeEndpoints().MapTenantAdminEndpoints();

    /// <summary>Must be placed AFTER UseAuthentication() and BEFORE UseAuthorization()/endpoints.</summary>
    public static IApplicationBuilder UseTenantResolution(this IApplicationBuilder app) =>
        app.UseMiddleware<TenantResolutionMiddleware>();
}
