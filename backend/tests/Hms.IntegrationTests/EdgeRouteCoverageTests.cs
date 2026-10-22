using System.Text.Json;
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
        using var monolith = new WebApplicationFactory<Hms.Gateway.MonolithMarker>()
            .WithWebHostBuilder(b => b.UseEnvironment("Testing").UseSetting("Auth:Supabase:ProjectUrl", TestJwt.ProjectUrl));
        // Membership, overrides, the travel buffer and my-day are scheduling-service routes. The monolith
        // does not map them, so coverage has to read that host as well as the legacy all-in-one host.
        using var scheduling = new WebApplicationFactory<SchedulingServiceMarker>()
            .WithWebHostBuilder(b => b.UseEnvironment("Testing").UseSetting("Auth:Supabase:ProjectUrl", TestJwt.ProjectUrl));
        var onMonolith = ServedPrefixes(monolith).ToList();
        Assert.DoesNotContain(onMonolith, s => s.Prefix is "practitioner-branches" or "schedule-overrides" or "scheduling-settings");
        var served = onMonolith.Concat(ServedPrefixes(scheduling)).Distinct().ToList();
        Assert.NotEmpty(served);
        Assert.Contains(served, s => s.Prefix == "practitioner-branches" && s.Module == "Hms.Modules.Appointments");

        var routes = EdgeRoutes();
        foreach (var (prefix, module) in served)
        {
            Assert.True(routes.TryGetValue(prefix, out var cluster), $"/api/v1/{prefix} is served by {module} but has no edge route");
            Assert.True(module is not null && ModuleToCluster.ContainsKey(module), $"/api/v1/{prefix}: unknown owning module '{module}'");
            Assert.True(ModuleToCluster[module!] == cluster, $"/api/v1/{prefix} belongs to {module} ({ModuleToCluster[module!]}) but the edge routes it to {cluster}");
        }
    }

    private static IEnumerable<(string Prefix, string? Module)> ServedPrefixes<TEntry>(WebApplicationFactory<TEntry> factory)
        where TEntry : class =>
        factory.Services.GetRequiredService<EndpointDataSource>().Endpoints
            .OfType<RouteEndpoint>()
            .Select(e => (Pattern: e.RoutePattern.RawText ?? string.Empty, Module: e.Metadata.OfType<System.Reflection.MethodInfo>().FirstOrDefault()?.DeclaringType?.Assembly.GetName().Name))
            .Where(e => e.Pattern.TrimStart('/').StartsWith("api/v1/", StringComparison.Ordinal))
            .Select(e => (Prefix: e.Pattern.TrimStart('/').Split('/')[2], e.Module))
            .Where(e => e.Prefix != "warmup")
            .Distinct();

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
