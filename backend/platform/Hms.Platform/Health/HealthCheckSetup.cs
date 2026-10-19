using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Npgsql;

namespace Hms.Platform.Health;

public static class HealthCheckSetup
{
    private const string LiveTag = "live";
    private const string ReadyTag = "ready";

    /// <summary>
    /// /health/live = process only; /health/ready = can open a connection on the service's shared
    /// <see cref="NpgsqlDataSource"/> and run <c>select 1</c> (no table access: the login role owns nothing).
    /// </summary>
    public static IServiceCollection AddHmsHealthChecks(this IServiceCollection services)
    {
        services.AddHealthChecks()
            .AddCheck("self", () => HealthCheckResult.Healthy(), tags: [LiveTag])
            .AddCheck<DatabaseHealthCheck>("database", tags: [ReadyTag]);
        return services;
    }

    public static IEndpointRouteBuilder MapHmsHealthChecks(this IEndpointRouteBuilder app)
    {
        app.MapHealthChecks("/health/live", new HealthCheckOptions { Predicate = c => c.Tags.Contains(LiveTag), ResponseWriter = WriteAsync })
            .AllowAnonymous().DisableRateLimiting();
        app.MapHealthChecks("/health/ready", new HealthCheckOptions { Predicate = c => c.Tags.Contains(ReadyTag), ResponseWriter = WriteAsync })
            .AllowAnonymous().DisableRateLimiting();
        return app;
    }

    // Deliberately minimal: no exception messages / connection details leak out.
    private static Task WriteAsync(HttpContext context, HealthReport report)
    {
        context.Response.ContentType = "application/json";
        var payload = new
        {
            status = report.Status.ToString(),
            checks = report.Entries.Select(e => new { name = e.Key, status = e.Value.Status.ToString(), durationMs = Math.Round(e.Value.Duration.TotalMilliseconds, 1) }),
        };
        return context.Response.WriteAsync(JsonSerializer.Serialize(payload, JsonSerializerOptions.Web));
    }
}

internal sealed class DatabaseHealthCheck(NpgsqlDataSource dataSource) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            await using var command = dataSource.CreateCommand("select 1");
            await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
            return HealthCheckResult.Healthy();
        }
#pragma warning disable CA1031 // any failure means "not ready"; details stay in the (non-public) exception
        catch (Exception ex)
#pragma warning restore CA1031
        {
            return HealthCheckResult.Unhealthy("database unavailable", ex);
        }
    }
}
