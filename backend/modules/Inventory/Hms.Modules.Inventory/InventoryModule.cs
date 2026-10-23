using Hms.Modules.Inventory.Endpoints;
using Hms.Modules.Inventory.Persistence;
using Hms.Platform.Persistence;
using Hms.Platform.Tenancy;
using Hms.SharedKernel.Persistence;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Hms.Modules.Inventory;

public static class InventoryModule
{
    public static IServiceCollection AddInventoryModule(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddHmsDbSession();
        services.AddDbContext<InventoryDbContext>((sp, options) => options
            .UseHmsNpgsql(configuration)
            .AddInterceptors(sp.GetRequiredService<RlsTransactionInterceptor>()));
        return services;
    }

    public static RouteGroupBuilder MapInventoryModule(this RouteGroupBuilder api) =>
        api.MapInventoryEndpoints();
}
