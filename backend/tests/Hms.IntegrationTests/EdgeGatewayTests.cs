using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Hms.Edge;
using Hms.Platform.Auth;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Yarp.ReverseProxy.Forwarder;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>The edge contract through the full in-process system (edge mode; other modes return early).</summary>
[Trait("Category", "Database")]
[Trait("Mode", "in-process-only")]
public sealed class EdgeGatewayTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private const string Prod = "https://medicore-hms-three.vercel.app";

    [Theory]
    [InlineData("identity", "/api/v1/me")]
    [InlineData("patients", "/api/v1/patients")]
    [InlineData("scheduling", "/api/v1/appointments")]
    public async Task Direct_service_calls_without_the_edge_key_are_404(string service, string path)
    {
        if (Target != SystemTarget.Edge)
        {
            return;
        }

        using var direct = factory.CreateServiceClient(service);
        direct.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", TestJwt.Create(AlphaAdmin));
        Assert.Equal(HttpStatusCode.NotFound, (await direct.GetAsync(path)).StatusCode);

        direct.DefaultRequestHeaders.Add("X-Hms-Edge-Key", "wrong-key");
        Assert.Equal(HttpStatusCode.NotFound, (await direct.GetAsync(path)).StatusCode);

        // health stays reachable for the platform probes
        using var probe = factory.CreateServiceClient(service);
        Assert.Equal(HttpStatusCode.OK, (await probe.GetAsync("/health/live")).StatusCode);

        // through the edge the same call works
        using var viaEdge = factory.ClientAs(AlphaAdmin, Alpha);
        Assert.Equal(HttpStatusCode.OK, (await viaEdge.GetAsync(path)).StatusCode);
    }

    [Fact]
    public async Task A_client_supplied_edge_key_or_tenant_header_is_stripped_not_trusted()
    {
        if (Target != SystemTarget.Edge)
        {
            return;
        }

        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        client.DefaultRequestHeaders.Add("X-Hms-Edge-Key", "attacker");
        client.DefaultRequestHeaders.Add("X-Hms-Tenant", Beta.ToString());
        var response = await client.GetAsync("/api/v1/tenants/current");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(Alpha.ToString(), response.Headers.GetValues("X-Hms-Tenant").Single()); // passed through on the response
    }

    [Theory]
    [InlineData("GET", "/internal/events")]
    [InlineData("POST", "/internal/events")]
    [InlineData("DELETE", "/internal/events/1")]
    [InlineData("PUT", "/Internal/events")]
    [InlineData("PATCH", "/INTERNAL")]
    [InlineData("POST", "/api/v1/internal/events")]
    [InlineData("POST", "/%69nternal/events")]
    [InlineData("POST", "/api/v1/%2Finternal/events")]
    [InlineData("POST", "/api/v1/%252Finternal/events")]
    [InlineData("GET", "/api/v1/patients/..%2Finternal")]
    [InlineData("GET", "/api/v1/patients/%5Cinternal")]
    [InlineData("OPTIONS", "/internal/events")]
    public async Task Internal_paths_are_blocked_for_every_method_and_encoding(string method, string path)
    {
        if (Target != SystemTarget.Edge)
        {
            return;
        }

        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        using var request = new HttpRequestMessage(new HttpMethod(method), path);
        Assert.Equal(HttpStatusCode.NotFound, (await client.SendAsync(request)).StatusCode);
    }

    [Fact]
    public async Task Unknown_api_route_is_404_problem()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        var response = await client.GetAsync("/api/v1/no-such-service");
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task Request_id_is_echoed_and_generated_when_missing()
    {
        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/v1/me");
        request.Headers.Add("X-Request-Id", "qa-ref-123");
        var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("qa-ref-123", response.Headers.GetValues("X-Request-Id").Single());

        var generated = await client.GetAsync("/api/v1/me");
        Assert.Matches("^[0-9a-f]{32}$", generated.Headers.GetValues("X-Request-Id").Single());
    }

    [Fact]
    public async Task Cors_preflight_allows_prod_and_project_previews_with_max_age()
    {
        if (Target != SystemTarget.Edge)
        {
            return;
        }

        using var client = factory.CreateClient();
        foreach (var origin in new[] { Prod, "https://medicore-hms-git-feature-x-kakani-devs-projects.vercel.app" })
        {
            using var preflight = new HttpRequestMessage(HttpMethod.Options, "/api/v1/patients");
            preflight.Headers.Add("Origin", origin);
            preflight.Headers.Add("Access-Control-Request-Method", "PATCH");
            preflight.Headers.Add("Access-Control-Request-Headers", "authorization,content-type,x-request-id");
            var response = await client.SendAsync(preflight);
            Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
            Assert.Equal(origin, response.Headers.GetValues("Access-Control-Allow-Origin").Single());
            Assert.Equal("600", response.Headers.GetValues("Access-Control-Max-Age").Single());
        }

        foreach (var origin in new[] { "https://evil.vercel.app", "https://medicore-hms-three.vercel.app.evil.com" })
        {
            using var preflight = new HttpRequestMessage(HttpMethod.Options, "/api/v1/patients");
            preflight.Headers.Add("Origin", origin);
            preflight.Headers.Add("Access-Control-Request-Method", "GET");
            var response = await client.SendAsync(preflight);
            Assert.False(response.Headers.Contains("Access-Control-Allow-Origin"), origin);
        }
    }

    [Fact]
    public async Task Edge_generated_401_carries_cors_and_exposes_the_spa_headers()
    {
        if (Target != SystemTarget.Edge)
        {
            return;
        }

        using var client = factory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/v1/patients");
        request.Headers.Add("Origin", Prod);
        var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        Assert.Equal(Prod, response.Headers.GetValues("Access-Control-Allow-Origin").Single());
        var exposed = string.Join(",", response.Headers.GetValues("Access-Control-Expose-Headers"));
        Assert.Contains("X-Hms-Tenant", exposed, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("X-Request-Id", exposed, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("Retry-After", exposed, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Proxied_responses_carry_cors_once_and_security_headers_once()
    {
        if (Target != SystemTarget.Edge)
        {
            return;
        }

        using var client = factory.ClientAs(AlphaAdmin, Alpha);
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/v1/me");
        request.Headers.Add("Origin", Prod);
        var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(Prod, response.Headers.GetValues("Access-Control-Allow-Origin").Single());
        Assert.Equal("nosniff", response.Headers.GetValues("X-Content-Type-Options").Single());
    }

    [Fact]
    public async Task Warmup_is_anonymous_and_reports_every_service()
    {
        if (Target != SystemTarget.Edge)
        {
            return;
        }

        using var client = factory.CreateClient();
        var response = await client.GetAsync("/api/v1/warmup");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadAsStringAsync();
        foreach (var svc in new[] { "identity", "patients", "scheduling" })
        {
            Assert.Contains($"\"name\":\"{svc}\"", body, StringComparison.Ordinal);
        }
    }
}

/// <summary>Edge behaviour when a service or the key server is down (no database needed).</summary>
[Trait("Mode", "in-process-only")]
public sealed class EdgeResilienceTests
{
    private const string Prod = "https://medicore-hms-three.vercel.app";

    [Fact]
    public async Task Unreachable_service_is_503_problem_with_retry_after_and_cors()
    {
        await using var edge = new DownstreamDownEdge(jwksDown: false);
        using var client = edge.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/v1/patients");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", TestJwt.Create(HmsApiFactory.AlphaAdmin));
        request.Headers.Add("Origin", Prod);
        var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Equal("5", response.Headers.GetValues("Retry-After").Single());
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType!.MediaType);
        Assert.Contains("\"code\":\"service_unavailable\"", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        Assert.Equal(Prod, response.Headers.GetValues("Access-Control-Allow-Origin").Single());
    }

    [Fact]
    public async Task Readiness_and_warmup_are_503_while_a_service_is_down()
    {
        await using var edge = new DownstreamDownEdge(jwksDown: false);
        using var client = edge.CreateClient();
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/health/live")).StatusCode);
        var ready = await client.GetAsync("/health/ready");
        Assert.Equal(HttpStatusCode.ServiceUnavailable, ready.StatusCode);
        Assert.Equal("5", ready.Headers.GetValues("Retry-After").Single());
        Assert.Equal(HttpStatusCode.ServiceUnavailable, (await client.GetAsync("/api/v1/warmup")).StatusCode);
    }

    [Fact]
    public async Task Jwks_outage_is_503_not_401()
    {
        await using var edge = new DownstreamDownEdge(jwksDown: true);
        using var client = edge.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/v1/me");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", TestJwt.Create(HmsApiFactory.AlphaAdmin));
        request.Headers.Add("Origin", Prod);
        var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Equal("5", response.Headers.GetValues("Retry-After").Single());
        Assert.Contains("\"code\":\"service_unavailable\"", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        Assert.Equal(Prod, response.Headers.GetValues("Access-Control-Allow-Origin").Single());

        // a genuinely bad token is still 401 (no JWKS needed to reject a missing token)
        using var anonymous = edge.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await anonymous.GetAsync("/api/v1/me")).StatusCode);
    }

    [Fact]
    public async Task Too_many_requests_is_429_problem_with_retry_after()
    {
        await using var edge = new DownstreamDownEdge(jwksDown: false, permitPerMinute: 1);
        using var client = edge.CreateClient();
        client.DefaultRequestHeaders.Add("Origin", Prod);
        await client.GetAsync("/api/v1/me");
        var limited = await client.GetAsync("/api/v1/me");
        Assert.Equal(HttpStatusCode.TooManyRequests, limited.StatusCode);
        Assert.True(int.Parse(limited.Headers.GetValues("Retry-After").Single(), System.Globalization.CultureInfo.InvariantCulture) >= 1);
        Assert.Equal(Prod, limited.Headers.GetValues("Access-Control-Allow-Origin").Single());
    }

    [Theory]
    [InlineData("/internal", true)]
    [InlineData("/Internal/x", true)]
    [InlineData("/api/v1/%2finternal", true)]
    [InlineData("/api/v1/%252Finternal", true)]
    [InlineData("/a\\internal\\b", true)]
    [InlineData("/internal./x", true)]
    [InlineData("/api/v1/internals", false)]
    [InlineData("/api/v1/patients?q=internal", false)]
    public void Internal_path_detection(string path, bool blocked) => Assert.Equal(blocked, EdgeHost.IsInternalPath(path));

    private sealed class DownstreamDownEdge(bool jwksDown, int permitPerMinute = 100000) : WebApplicationFactory<EdgeMarker>
    {
        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.UseEnvironment("Testing");
            builder.UseSetting("Auth:Supabase:ProjectUrl", TestJwt.ProjectUrl);
            builder.UseSetting("RateLimiting:PermitPerMinute", permitPerMinute.ToString(System.Globalization.CultureInfo.InvariantCulture));
            builder.UseSetting("Edge:Key", "k");
            foreach (var svc in new[] { "identity", "patients", "scheduling" })
            {
                builder.UseSetting($"ReverseProxy:Clusters:{svc}:Destinations:primary:Address", $"http://{svc}.down.test/");
            }

            builder.ConfigureTestServices(services =>
            {
                services.RemoveAll<IForwarderHttpClientFactory>();
                services.AddSingleton<IForwarderHttpClientFactory>(new DownFactory());
                services.AddHttpClient(EdgeHost.UpstreamHttpClient).ConfigurePrimaryHttpMessageHandler(() => new RefusingHandler());
                services.AddHttpClient(SupabaseAuthOptions.JwksHttpClient).ConfigurePrimaryHttpMessageHandler(() =>
                    jwksDown ? new RefusingHandler() : new JwksHandler());
            });
        }
    }

    private sealed class DownFactory : IForwarderHttpClientFactory
    {
        public HttpMessageInvoker CreateClient(ForwarderHttpClientContext context) => new(new RefusingHandler());
    }

    private sealed class RefusingHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            throw new HttpRequestException("Connection refused (test)");
    }

    private sealed class JwksHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(TestJwt.JwksJson, Encoding.UTF8, "application/json"),
            });
    }
}
