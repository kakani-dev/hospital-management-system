using System.Text.Json;
using Hms.Identity.Api;
using Hms.Patients.Api;
using Hms.Scheduling.Api;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;

namespace Hms.IntegrationTests;

/// <summary>
/// Every /api/v1 prefix served by a module must be routed by the edge to the service that hosts that
/// module, or it silently becomes a 404 behind the single base URL. No database needed.
/// </summary>
public sealed class EdgeRouteCoverageTests
{
    private static readonly Dictionary<string, string> ModuleToCluster = new(StringComparer.Ordinal)
    {
        ["Hms.Modules.Identity"] = "identity",
        ["Hms.Modules.Patients"] = "patients",
        ["Hms.Modules.Appointments"] = "scheduling",
    };

    [Fact]
    public void Every_module_api_prefix_is_routed_by_the_edge_to_its_owning_service()
    {
        var served = Prefixes<IdentityServiceMarker>()
            .Concat(Prefixes<PatientsServiceMarker>())
            .Concat(Prefixes<SchedulingServiceMarker>())
            .Distinct()
            .ToList();
        Assert.NotEmpty(served);

        var routes = EdgeRoutes();
        foreach (var (prefix, module) in served)
        {
            Assert.True(routes.TryGetValue(prefix, out var cluster), $"/api/v1/{prefix} is served by {module} but has no edge route");
            Assert.True(module is not null && ModuleToCluster.ContainsKey(module), $"/api/v1/{prefix}: unknown owning module '{module}'");
            Assert.True(ModuleToCluster[module!] == cluster, $"/api/v1/{prefix} belongs to {module} ({ModuleToCluster[module!]}) but the edge routes it to {cluster}");
        }
    }

    private static IEnumerable<(string Prefix, string? Module)> Prefixes<TMarker>()
        where TMarker : class
    {
        using var host = new WebApplicationFactory<TMarker>()
            .WithWebHostBuilder(b => b.UseEnvironment("Testing").UseSetting("Auth:Supabase:ProjectUrl", TestJwt.ProjectUrl));
        return host.Services.GetRequiredService<EndpointDataSource>().Endpoints
            .OfType<RouteEndpoint>()
            .Select(e => (Pattern: e.RoutePattern.RawText ?? string.Empty, Module: e.Metadata.OfType<System.Reflection.MethodInfo>().FirstOrDefault()?.DeclaringType?.Assembly.GetName().Name))
            .Where(e => e.Pattern.TrimStart('/').StartsWith("api/v1/", StringComparison.Ordinal))
            .Select(e => (Prefix: e.Pattern.TrimStart('/').Split('/')[2], e.Module))
            .Where(e => e.Prefix != "warmup");
    }

    private static Dictionary<string, string> EdgeRoutes()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Hms.slnx")))
        {
            dir = dir.Parent;
        }

        var path = Path.Combine(dir!.FullName, "edge", "Hms.Edge", "appsettings.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var route in doc.RootElement.GetProperty("ReverseProxy").GetProperty("Routes").EnumerateObject())
        {
            var match = route.Value.GetProperty("Match").GetProperty("Path").GetString()!;
            result[match.TrimStart('/').Split('/')[2]] = route.Value.GetProperty("ClusterId").GetString()!;
        }

        return result;
    }
}
