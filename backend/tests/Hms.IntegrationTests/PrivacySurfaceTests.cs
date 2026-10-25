using Hms.Modules.Privacy;
using Hms.Privacy.Api;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;

namespace Hms.IntegrationTests;

/// <summary>Privacy route shape. No database: the public link must be anonymous and rate limited.</summary>
public sealed class PrivacySurfaceTests
{
    [Fact]
    public void Public_consent_routes_are_anonymous_and_rate_limited()
    {
        using var host = new WebApplicationFactory<PrivacyServiceMarker>()
            .WithWebHostBuilder(b => b.UseEnvironment("Testing").UseSetting("Auth:Supabase:ProjectUrl", TestJwt.ProjectUrl));
        var publics = host.Services.GetRequiredService<EndpointDataSource>().Endpoints
            .OfType<RouteEndpoint>()
            .Where(e => (e.RoutePattern.RawText ?? string.Empty).Contains("privacy/public/consents", StringComparison.Ordinal))
            .ToList();
        Assert.Equal(2, publics.Count);
        Assert.All(publics, endpoint =>
        {
            Assert.Equal(PrivacyModule.PublicPolicy, endpoint.Metadata.GetMetadata<EnableRateLimitingAttribute>()?.PolicyName);
            Assert.Contains(endpoint.Metadata, meta => meta is IAllowAnonymous);
        });
    }
}
