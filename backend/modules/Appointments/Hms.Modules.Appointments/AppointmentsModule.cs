using Hms.Modules.Appointments.Endpoints;
using Hms.Modules.Appointments.Functions;
using Hms.Modules.Appointments.Persistence;
using Hms.Platform.Persistence;
using Hms.Platform.Tenancy;
using Hms.SharedKernel.Persistence;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hms.Modules.Appointments;

public static class AppointmentsModule
{
    public static IServiceCollection AddAppointmentsModule(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddHmsDbSession();
        services.AddDbContext<AppointmentsDbContext>((sp, options) => options
            .UseHmsNpgsql(configuration)
            .AddInterceptors(
                sp.GetRequiredService<RlsTransactionInterceptor>(),
                sp.GetRequiredService<TenantSaveChangesInterceptor>()));
        services.TryAddScoped<IAppointmentFunctions, PostgresAppointmentFunctions>();
        services.TryAddScoped<IPatientSummaries, PostgresPatientSummaries>();
        return services;
    }

    /// <summary>
    /// Routes the legacy monolith still serves. Branch membership, day overrides, the travel buffer
    /// and my-day are mapped only by the scheduling service (<c>MapPractitionerBranchEndpoints</c>).
    /// </summary>
    public static RouteGroupBuilder MapAppointmentsModule(this RouteGroupBuilder api) =>
        api.MapPractitionerScheduleEndpoints().MapClinicalMasterEndpoints().MapAppointmentEndpoints().MapQueueEndpoints().MapConsultationEndpoints();
}
