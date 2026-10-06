using Hms.Modules.Patients.Persistence;
using Hms.SharedKernel.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hms.Modules.Patients;

public static class PatientsModule
{
    public static IServiceCollection AddPatientsModule(this IServiceCollection services, IConfiguration configuration)
    {
        var connectionString = configuration.GetConnectionString("HmsDatabase");
        services.TryAddScoped<DbSessionContext>();
        services.TryAddScoped<RlsTransactionInterceptor>();
        services.TryAddScoped<TenantSaveChangesInterceptor>();
        services.TryAddSingleton(TimeProvider.System);
        services.AddDbContext<PatientsDbContext>((sp, options) => options
            .UseNpgsql(connectionString)
            .UseSnakeCaseNamingConvention()
            .AddInterceptors(
                sp.GetRequiredService<RlsTransactionInterceptor>(),
                sp.GetRequiredService<TenantSaveChangesInterceptor>()));
        return services;
    }
}
