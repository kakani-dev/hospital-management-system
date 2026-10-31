using Hangfire;
using Hangfire.InMemory;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Options;

namespace Hms.Modules.Appointments.Reminders;

public static class RemindersSetup
{
    /// <summary>Options, channels and the sweep. Hangfire itself only starts when Reminders:Mode is not Off.</summary>
    public static IServiceCollection AddAppointmentReminders(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<ReminderOptions>(configuration.GetSection(ReminderOptions.Section));
        services.Configure<ReminderSmtpOptions>(configuration.GetSection(ReminderSmtpOptions.Section));
        services.TryAddScoped<IReminderStore, PostgresReminderStore>();
        services.AddScoped<IReminderChannel, EmailReminderChannel>();
        services.AddHttpClient<WahaReminderChannel>();
        services.AddScoped<IReminderChannel>(sp => sp.GetRequiredService<WahaReminderChannel>());
        services.TryAddScoped<ReminderSweep>();

        var options = configuration.GetSection(ReminderOptions.Section).Get<ReminderOptions>() ?? new ReminderOptions();
        if (options.DeliveryMode != ReminderDeliveryMode.Off)
        {
            services.AddHangfire(c => c.UseSimpleAssemblyNameTypeSerializer().UseRecommendedSerializerSettings().UseInMemoryStorage());
            services.AddHangfireServer(o => o.WorkerCount = 1);
        }

        return services;
    }

    public static WebApplication UseAppointmentReminderJobs(this WebApplication app)
    {
        var options = app.Services.GetRequiredService<IOptions<ReminderOptions>>().Value;
        if (options.DeliveryMode != ReminderDeliveryMode.Off)
        {
            app.Services.GetRequiredService<IRecurringJobManager>()
                .AddOrUpdate<ReminderSweep>(ReminderSweep.JobId, s => s.RunAsync(CancellationToken.None), options.SweepCron);
        }

        return app;
    }
}
