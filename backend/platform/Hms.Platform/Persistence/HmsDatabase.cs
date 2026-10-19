using System.Data.Common;
using System.Globalization;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Npgsql;

namespace Hms.Platform.Persistence;

/// <summary>
/// The ONE place that turns configuration into a PostgreSQL connection for every HMS service.
/// <list type="bullet">
/// <item><c>No Reset On Close=true</c> is forced (unless the connection string sets it explicitly):
/// Npgsql's <c>DISCARD ALL</c> on pooled-connection return hangs through the Supavisor transaction
/// pooler (:6543), which made <c>/health/ready</c> flap on Azure. It is safe here because the API
/// never sets session-level state: the RLS role/claims and the dispatcher role are always
/// transaction-local (<c>set_config(..., true)</c> / <c>SET LOCAL ROLE</c>).</item>
/// <item><c>Database:MaxPoolSize</c> (optional) caps the pool per service, so several services fit the
/// Supabase pooler client limit (MICROSERVICES-PLAN.md §3.4).</item>
/// </list>
/// </summary>
public static class HmsDatabase
{
    public const string ConnectionStringName = "HmsDatabase";
    public const string MaxPoolSizeKey = "Database:MaxPoolSize";

    /// <summary>Normalised connection string, or an empty string when none is configured (fail at first use).</summary>
    public static string ConnectionString(IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var raw = configuration.GetConnectionString(ConnectionStringName);
        if (string.IsNullOrWhiteSpace(raw))
        {
            return string.Empty;
        }

        return Normalize(raw, configuration[MaxPoolSizeKey]);
    }

    internal static string Normalize(string raw, string? maxPoolSize = null)
    {
        var builder = new NpgsqlConnectionStringBuilder(raw);
        if (!ExplicitlySet(raw, "No Reset On Close"))
        {
            builder.NoResetOnClose = true;
        }

        if (!string.IsNullOrWhiteSpace(maxPoolSize))
        {
            builder.MaxPoolSize = int.Parse(maxPoolSize, NumberStyles.Integer, CultureInfo.InvariantCulture);
        }

        return builder.ConnectionString;
    }

    /// <summary>
    /// Registers the shared <see cref="NpgsqlDataSource"/> (health checks, tenant resolution, outbox).
    /// Built lazily on first use, from the same normalised connection string the DbContexts use.
    /// </summary>
    public static IServiceCollection AddHmsDatabase(this IServiceCollection services, IConfiguration configuration)
    {
        services.TryAddSingleton(_ => new NpgsqlDataSourceBuilder(ConnectionString(configuration)).Build());
        return services;
    }

    /// <summary><c>UseNpgsql</c> with the normalised connection string and the HMS conventions.</summary>
    public static DbContextOptionsBuilder UseHmsNpgsql(this DbContextOptionsBuilder options, IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(options);
        return options.UseNpgsql(ConnectionString(configuration)).UseSnakeCaseNamingConvention();
    }

    // Explicitly configured either way ("No Reset On Close" / "NoResetOnClose", any case)? Then respect it.
    private static bool ExplicitlySet(string raw, string key)
    {
        var generic = new DbConnectionStringBuilder { ConnectionString = raw };
        var wanted = Squash(key);
        return generic.Keys.Cast<string>().Any(k => Squash(k) == wanted);
    }

    private static string Squash(string key) => key.Replace(" ", string.Empty, StringComparison.Ordinal).ToUpperInvariant();
}
