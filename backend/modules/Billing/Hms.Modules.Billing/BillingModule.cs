using Hms.Modules.Billing.Caching;
using Hms.Modules.Billing.Endpoints;
using Hms.Modules.Billing.Payments;
using Hms.Modules.Billing.Persistence;
using Hms.Platform.Persistence;
using Hms.Platform.Tenancy;
using Hms.SharedKernel.Persistence;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hms.Modules.Billing;

public static class BillingModule
{
    public static IServiceCollection AddBillingModule(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddHmsDbSession();
        services.AddDbContext<BillingDbContext>((sp, options) => options
            .UseHmsNpgsql(configuration)
            .AddInterceptors(sp.GetRequiredService<RlsTransactionInterceptor>()));
        services.AddMemoryCache();
        services.TryAddSingleton(TimeProvider.System);
        services.AddSingleton<EarningsReportCache>();
        services.Configure<BillingPaymentOptions>(configuration.GetSection(BillingPaymentOptions.Section));
        services.TryAddSingleton<IPaymentProvider, StubPaymentProvider>();
        services.TryAddSingleton<IBillShareSender, StubBillShareSender>();
        return services;
    }

    public static RouteGroupBuilder MapBillingModule(this RouteGroupBuilder api) =>
        api.MapBillingEndpoints();
}
