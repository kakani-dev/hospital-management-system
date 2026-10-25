using Hms.Platform.Health;
using Hms.Platform.Persistence;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Hms.Platform.Messaging;

public static class OutboxSetup
{
    /// <summary>
    /// Registers the outbox dispatcher (a no-op unless Outbox:Dispatcher:Enabled=true).
    /// DryRun defaults to true, so the first enablement only reports the backlog.
    /// It uses the service's shared <see cref="Npgsql.NpgsqlDataSource"/> (<see cref="HmsDatabase.AddHmsDatabase"/>).
    /// </summary>
    public static IServiceCollection AddHmsOutboxDispatcher(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<OutboxOptions>(configuration.GetSection(OutboxOptions.Section));
        services.AddHmsDatabase(configuration);
        services.AddSingleton<OutboxDispatcherHealth>();
        services.AddSingleton<IOutboxStore, PostgresOutboxStore>();
        services.AddSingleton<IOutboxPublisher, LoggingOutboxPublisher>();
        services.AddHealthChecks().AddCheck<OutboxDispatcherHealthCheck>("outbox-dispatcher", tags: [HealthCheckSetup.ReadyTag]);
        services.AddHostedService<OutboxDispatcher>();
        return services;
    }
}
