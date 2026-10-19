using Hms.Modules.Patients.Persistence;
using Hms.Modules.Patients.Registry;
using Hms.Platform.Persistence;
using Hms.Platform.Tenancy;
using Hms.SharedKernel.Persistence;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hms.Modules.Patients;

public static class PatientsModule
{
    public static IServiceCollection AddPatientsModule(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddHmsDbSession();
        services.AddDbContext<PatientsDbContext>((sp, options) => options
            .UseHmsNpgsql(configuration)
            .AddInterceptors(
                sp.GetRequiredService<RlsTransactionInterceptor>(),
                sp.GetRequiredService<TenantSaveChangesInterceptor>()));
        services.TryAddScoped<IPatientRegistryFunctions, PostgresPatientRegistryFunctions>();
        return services;
    }
}
