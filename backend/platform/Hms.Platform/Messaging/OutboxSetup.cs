using Hms.Platform.Persistence;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Hms.Platform.Messaging;

public static class OutboxSetup
{
    /// <summary>
    /// Registers the outbox dispatcher (a no-op unless Outbox:Dispatcher:Enabled=true). It uses the
    /// service's shared <see cref="Npgsql.NpgsqlDataSource"/> (<see cref="HmsDatabase.AddHmsDatabase"/>),
    /// so a disabled dispatcher no longer opens a second connection pool (PR #2 review nit).
    /// </summary>
    public static IServiceCollection AddHmsOutboxDispatcher(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<OutboxOptions>(configuration.GetSection(OutboxOptions.Section));
        services.AddHmsDatabase(configuration);
        services.AddSingleton<IOutboxStore, PostgresOutboxStore>();
        services.AddSingleton<IOutboxPublisher, LoggingOutboxPublisher>();
        services.AddHostedService<OutboxDispatcher>();
        return services;
    }
}
