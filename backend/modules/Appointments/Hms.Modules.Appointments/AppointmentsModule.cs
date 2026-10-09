using Hms.Modules.Appointments.Endpoints;
using Hms.Modules.Appointments.Functions;
using Hms.Modules.Appointments.Persistence;
using Hms.SharedKernel.Persistence;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hms.Modules.Appointments;

public static class AppointmentsModule
{
    public static IServiceCollection AddAppointmentsModule(this IServiceCollection services, IConfiguration configuration)
    {
        var connectionString = configuration.GetConnectionString("HmsDatabase");
        services.TryAddScoped<DbSessionContext>();
        services.TryAddScoped<RlsTransactionInterceptor>();
        services.TryAddScoped<TenantSaveChangesInterceptor>();
        services.TryAddSingleton(TimeProvider.System);
        services.AddDbContext<AppointmentsDbContext>((sp, options) => options
            .UseNpgsql(connectionString)
            .UseSnakeCaseNamingConvention()
            .AddInterceptors(
                sp.GetRequiredService<RlsTransactionInterceptor>(),
                sp.GetRequiredService<TenantSaveChangesInterceptor>()));
        services.TryAddScoped<IAppointmentFunctions, PostgresAppointmentFunctions>();
        return services;
    }

    public static RouteGroupBuilder MapAppointmentsModule(this RouteGroupBuilder api) =>
        api.MapPractitionerScheduleEndpoints().MapAppointmentEndpoints().MapQueueEndpoints();
}
