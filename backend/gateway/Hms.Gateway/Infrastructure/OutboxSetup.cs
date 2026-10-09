using Hms.SharedKernel.Messaging;
using Npgsql;

namespace Hms.Gateway.Infrastructure;

public static class OutboxSetup
{
    /// <summary>Registers the outbox dispatcher (a no-op unless Outbox:Dispatcher:Enabled=true).</summary>
    public static IServiceCollection AddHmsOutboxDispatcher(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<OutboxOptions>(configuration.GetSection(OutboxOptions.Section));
        var connectionString = configuration.GetConnectionString("HmsDatabase");
        services.AddSingleton(_ => new NpgsqlDataSourceBuilder(connectionString).Build());
        services.AddSingleton<IOutboxStore, PostgresOutboxStore>();
        services.AddSingleton<IOutboxPublisher, LoggingOutboxPublisher>();
        services.AddHostedService<OutboxDispatcher>();
        return services;
    }
}
