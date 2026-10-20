using Microsoft.Extensions.DependencyInjection.Extensions;
using Hms.Modules.Identity.Endpoints;
using Hms.Modules.Identity.Persistence;
using Hms.Platform.Persistence;
using Hms.Platform.Tenancy;
using Hms.SharedKernel.Persistence;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Hms.Modules.Identity;

/// <summary>
/// Identity module: tenants, branches, memberships, invitations, /me. Tenant RESOLUTION (used by
/// every service) lives in Hms.Platform and reads identity's published SQL surface, not this DbContext.
/// </summary>
public static class IdentityModule
{
    public static IServiceCollection AddIdentityModule(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddHmsDbSession();
        services.AddMemoryCache();
        services.TryAddSingleton(TimeProvider.System);
        services.AddSingleton<Caching.TenantReferenceCache>();
        services.AddDbContext<IdentityDbContext>((sp, options) => options
            .UseHmsNpgsql(configuration)
            .AddInterceptors(
                sp.GetRequiredService<RlsTransactionInterceptor>(),
                sp.GetRequiredService<TenantSaveChangesInterceptor>()));
        return services;
    }

    public static RouteGroupBuilder MapIdentityEndpoints(this RouteGroupBuilder api) =>
        api.MapMeEndpoints().MapInviteLinkEndpoints().MapTenantAdminEndpoints();
}
