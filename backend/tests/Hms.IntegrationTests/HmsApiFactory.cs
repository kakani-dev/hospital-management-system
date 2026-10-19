using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using Hms.Edge;
using Hms.Identity.Api;
using Hms.Patients.Api;
using Hms.Platform.Auth;
using Hms.Scheduling.Api;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Npgsql;
using Yarp.ReverseProxy.Forwarder;

namespace Hms.IntegrationTests;

/// <summary>Which system the API tests drive (QA-MICROSERVICES-TEST-PLAN.md §1.2). Env HMS_SYSTEM_TARGET.</summary>
public enum SystemTarget
{
    /// <summary>Default (CI): the YARP edge in front of identity / patients / scheduling, all in-process.</summary>
    Edge,

    /// <summary>The legacy all-in-one host (Hms.Gateway), until the monolith is retired (Phase 6).</summary>
    Monolith,

    /// <summary>A running edge (docker compose / deployed dev) at HMS_SYSTEM_BASE_URL; tokens from mock-auth.</summary>
    EdgeUrl,
}

/// <summary>
/// The API under test against the REAL PostgreSQL database prepared by supabase/scripts/run-sql-tests.sh
/// (migrations + synthetic seed), with real JWT bearer validation against a fake JWKS endpoint. Every
/// test talks HTTP to <see cref="CreateClient"/>; what answers depends on <see cref="Target"/>:
/// <list type="bullet">
/// <item><c>edge</c> (default): Hms.Edge (YARP) -> Hms.Identity.Api / Hms.Patients.Api / Hms.Scheduling.Api,
/// each a separate in-process host with its OWN login role (hms_&lt;svc&gt;_login) and the edge key.</item>
/// <item><c>monolith</c>: the legacy Hms.Gateway host as hms_api_login.</item>
/// <item><c>edge-url</c>: HMS_SYSTEM_BASE_URL (e.g. the compose edge); tokens come from mock-auth
/// (HMS_SYSTEM_AUTH_URL, password E2E_PASSWORD), so tests that mint custom JWTs do not apply there.</item>
/// </list>
/// </summary>
public class HmsApiFactory : IDisposable
{
    public static readonly string ApiConnection =
        Environment.GetEnvironmentVariable("HMS_API_TEST_CONNECTION")
        ?? "Host=localhost;Port=5432;Database=hms_sql_test;Username=hms_api_login;Password=hms_api_local_only";

    /// <summary>
    /// A per-service login (hms_&lt;svc&gt;_login, supabase/scripts/local-api-login-role.sql) on the same
    /// database as <see cref="ApiConnection"/>; HMS_&lt;SVC&gt;_TEST_CONNECTION overrides it.
    /// </summary>
    public static string ServiceConnection(string service) =>
        Environment.GetEnvironmentVariable($"HMS_{service.ToUpperInvariant()}_TEST_CONNECTION")
        ?? new NpgsqlConnectionStringBuilder(ApiConnection)
        {
            Username = $"hms_{service}_login",
            Password = $"hms_{service}_local_only",
        }.ConnectionString;

    public static readonly string AdminConnection =
        Environment.GetEnvironmentVariable("HMS_DB_TEST_CONNECTION")
        ?? "Host=localhost;Port=5432;Database=hms_sql_test;Username=postgres;Password=postgres";

    public static readonly SystemTarget Target = ParseTarget(Environment.GetEnvironmentVariable("HMS_SYSTEM_TARGET"));

    /// <summary>Shared secret between the in-process edge and services (X-Hms-Edge-Key).</summary>
    public const string EdgeKey = "integration-test-edge-key";

    public static readonly Guid Alpha = Guid.Parse("11111111-1111-4111-8111-111111111111");
    public static readonly Guid Beta = Guid.Parse("22222222-2222-4222-8222-222222222222");
    public static readonly Guid AlphaMain = Guid.Parse("a1111111-0000-4000-8000-000000000001");
    public static readonly Guid AlphaEast = Guid.Parse("a1111111-0000-4000-8000-000000000002");
    public static readonly Guid BetaMain = Guid.Parse("b2222222-0000-4000-8000-000000000001");
    public static readonly Guid AlphaAdmin = Guid.Parse("0a000000-0000-4000-8000-000000000001");
    public static readonly Guid AlphaReception = Guid.Parse("0a000000-0000-4000-8000-000000000002");
    public static readonly Guid AlphaLab = Guid.Parse("0a000000-0000-4000-8000-000000000003");
    public static readonly Guid BetaAdmin = Guid.Parse("0b000000-0000-4000-8000-000000000001");
    public static readonly Guid BetaDoctor = Guid.Parse("0b000000-0000-4000-8000-000000000002");
    public static readonly Guid Outsider = Guid.Parse("0c000000-0000-4000-8000-000000000001");
    public static readonly Guid BetaPatientId = Guid.Parse("bb000000-0000-4000-8000-000000000001");
    public static readonly Guid AlphaPatientId = Guid.Parse("aa000000-0000-4000-8000-000000000001");

    private readonly List<StubJwksHandler> _jwks = [];
    private readonly Lazy<IHost> _host;

    public HmsApiFactory()
    {
        _host = new Lazy<IHost>(Build);
    }

    /// <summary>JWKS fetches by the busiest single host (each host caches its own key set).</summary>
    public int JwksRequests => _jwks.Count == 0 ? 0 : _jwks.Max(j => j.Requests);

    protected virtual string? LegacySecret => null;

    /// <summary>
    /// Extra host configuration applied to EVERY in-process host (monolith, each service, the edge),
    /// e.g. a fixed TimeProvider. Not applied in edge-url mode (nothing runs in-process there).
    /// </summary>
    protected virtual void ConfigureHost(IWebHostBuilder builder)
    {
    }

    public HttpClient CreateClient() => _host.Value.CreateClient();

    /// <summary>Direct client to one in-process service, bypassing the edge (edge mode only).</summary>
    public HttpClient CreateServiceClient(string service) =>
        _host.Value is EdgeSystem edge ? edge.ServiceClient(service) : throw new InvalidOperationException("Only in edge mode.");

    public HttpClient ClientWithToken(string token)
    {
        var client = CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client;
    }

    /// <summary>Token for a user; tenant claim as the custom access token hook would issue it.</summary>
    public HttpClient ClientAs(Guid user, Guid? tenant = null, Guid? branch = null)
    {
        if (Target == SystemTarget.EdgeUrl)
        {
            return ClientWithToken(MockAuthToken(user));
        }

        var claims = new Dictionary<string, object>();
        if (tenant is { } t)
        {
            claims["tenant_id"] = t.ToString();
        }

        if (branch is { } b)
        {
            claims["branch_id"] = b.ToString();
        }

        return ClientWithToken(TestJwt.Create(user, claims));
    }

    public void Dispose()
    {
        if (_host.IsValueCreated)
        {
            _host.Value.Dispose();
        }

        GC.SuppressFinalize(this);
    }

    private static SystemTarget ParseTarget(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        null or "" or "edge" or "edge-inprocess" => SystemTarget.Edge,
        "monolith" => SystemTarget.Monolith,
        "edge-url" => SystemTarget.EdgeUrl,
        _ => throw new InvalidOperationException($"HMS_SYSTEM_TARGET must be edge, monolith or edge-url (got '{value}')."),
    };

    private IHost Build() => Target switch
    {
        SystemTarget.Monolith => new MonolithSystem(this),
        SystemTarget.EdgeUrl => new UrlSystem(),
        _ => new EdgeSystem(this),
    };

    private StubJwksHandler NewJwks()
    {
        var stub = new StubJwksHandler();
        lock (_jwks)
        {
            _jwks.Add(stub);
        }

        return stub;
    }

    private readonly string _onboardingSalt = Guid.NewGuid().ToString("N");

    private void ConfigureCommon(IWebHostBuilder builder, StubJwksHandler jwks)
    {
        builder.UseEnvironment("Testing");
        builder.UseSetting("Auth:Supabase:ProjectUrl", TestJwt.ProjectUrl);
        builder.UseSetting("Auth:Supabase:LegacyJwtSecret", LegacySecret ?? string.Empty);
        builder.UseSetting("RateLimiting:PermitPerMinute", "100000");
        // per-factory salt: the DB's per-source sign-up cap (3 / 24 h) must not leak across runs on a reused DB
        builder.UseSetting("Onboarding:SourceHashSalt", _onboardingSalt);
        builder.ConfigureTestServices(services =>
            services.AddHttpClient(SupabaseAuthOptions.JwksHttpClient).ConfigurePrimaryHttpMessageHandler(() => jwks));
        ConfigureHost(builder);
    }

    private static string MockAuthToken(Guid user)
    {
        var authUrl = Environment.GetEnvironmentVariable("HMS_SYSTEM_AUTH_URL") ?? "http://localhost:54321";
        var password = Environment.GetEnvironmentVariable("E2E_PASSWORD") ?? "synthetic-demo-pass";
        var email = EmailOfAsync(user).GetAwaiter().GetResult();
        using var http = new HttpClient();
        using var response = http.PostAsJsonAsync($"{authUrl.TrimEnd('/')}/auth/v1/token?grant_type=password", new { email, password })
            .GetAwaiter().GetResult();
        response.EnsureSuccessStatusCode();
        var body = response.Content.ReadFromJsonAsync<Dictionary<string, object>>().GetAwaiter().GetResult()!;
        return body["access_token"].ToString()!;
    }

    private interface IHost : IDisposable
    {
        HttpClient CreateClient();
    }

    private sealed class MonolithSystem(HmsApiFactory owner) : WebApplicationFactory<Hms.Gateway.MonolithMarker>, IHost
    {
        private readonly StubJwksHandler _jwks = owner.NewJwks();

        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            owner.ConfigureCommon(builder, _jwks);
            builder.UseSetting("ConnectionStrings:HmsDatabase", ApiConnection);
        }
    }

    private sealed class UrlSystem : IHost
    {
        private readonly Uri _baseUrl = new(Environment.GetEnvironmentVariable("HMS_SYSTEM_BASE_URL")
            ?? throw new InvalidOperationException("HMS_SYSTEM_TARGET=edge-url needs HMS_SYSTEM_BASE_URL."));

        public HttpClient CreateClient() => new() { BaseAddress = _baseUrl };

        public void Dispose()
        {
        }
    }

    /// <summary>One service host (its own login role, the edge key enforced).</summary>
    private sealed class ServiceSystem<TMarker>(HmsApiFactory owner, string service) : WebApplicationFactory<TMarker>
        where TMarker : class
    {
        private readonly StubJwksHandler _jwks = owner.NewJwks();

        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            owner.ConfigureCommon(builder, _jwks);
            builder.UseSetting("ConnectionStrings:HmsDatabase", ServiceConnection(service));
            builder.UseSetting("Edge:Key", EdgeKey);
        }
    }

    /// <summary>The YARP edge, whose upstream HTTP goes to the in-process service hosts.</summary>
    private sealed class EdgeSystem : WebApplicationFactory<EdgeMarker>, IHost
    {
        private readonly HmsApiFactory _owner;
        private readonly StubJwksHandler _jwks;
        private readonly ServiceSystem<IdentityServiceMarker> _identity;
        private readonly ServiceSystem<PatientsServiceMarker> _patients;
        private readonly ServiceSystem<SchedulingServiceMarker> _scheduling;
        private readonly UpstreamRouter _router;

        public EdgeSystem(HmsApiFactory owner)
        {
            _owner = owner;
            _jwks = owner.NewJwks();
            _identity = new ServiceSystem<IdentityServiceMarker>(owner, "identity");
            _patients = new ServiceSystem<PatientsServiceMarker>(owner, "patients");
            _scheduling = new ServiceSystem<SchedulingServiceMarker>(owner, "scheduling");
            _router = new UpstreamRouter(new Dictionary<string, Func<HttpMessageHandler>>(StringComparer.OrdinalIgnoreCase)
            {
                ["identity.hms.test"] = () => _identity.Server.CreateHandler(),
                ["patients.hms.test"] = () => _patients.Server.CreateHandler(),
                ["scheduling.hms.test"] = () => _scheduling.Server.CreateHandler(),
            });
        }

        public HttpClient ServiceClient(string service) => service switch
        {
            "identity" => _identity.CreateClient(),
            "patients" => _patients.CreateClient(),
            "scheduling" => _scheduling.CreateClient(),
            _ => throw new ArgumentOutOfRangeException(nameof(service)),
        };

        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            _owner.ConfigureCommon(builder, _jwks);
            builder.UseSetting("Edge:Key", EdgeKey);
            builder.UseSetting("RateLimiting:WarmupPerMinute", "100000");
            foreach (var svc in new[] { "identity", "patients", "scheduling" })
            {
                builder.UseSetting($"ReverseProxy:Clusters:{svc}:Destinations:primary:Address", $"http://{svc}.hms.test/");
            }

            builder.ConfigureTestServices(services =>
            {
                services.RemoveAll<IForwarderHttpClientFactory>();
                services.AddSingleton<IForwarderHttpClientFactory>(new RouterForwarderFactory(_router));
                services.AddHttpClient(EdgeHost.UpstreamHttpClient).ConfigurePrimaryHttpMessageHandler(() => _router.CreateHandler());
            });
        }

        protected override void Dispose(bool disposing)
        {
            base.Dispose(disposing);
            if (disposing)
            {
                _identity.Dispose();
                _patients.Dispose();
                _scheduling.Dispose();
            }
        }
    }

    /// <summary>Sends each upstream request to the in-process host named by its URI host.</summary>
    private sealed class UpstreamRouter(IReadOnlyDictionary<string, Func<HttpMessageHandler>> hosts)
    {
        private readonly Dictionary<string, HttpMessageInvoker> _invokers = new(StringComparer.OrdinalIgnoreCase);

        public HttpMessageHandler CreateHandler() => new RouterHandler(this);

        public Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var host = request.RequestUri!.Host;
            HttpMessageInvoker invoker;
            lock (_invokers)
            {
                if (!_invokers.TryGetValue(host, out invoker!))
                {
                    invoker = new HttpMessageInvoker(hosts[host](), disposeHandler: true);
                    _invokers[host] = invoker;
                }
            }

            return invoker.SendAsync(request, ct);
        }

        private sealed class RouterHandler(UpstreamRouter router) : HttpMessageHandler
        {
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
                router.SendAsync(request, cancellationToken);
        }
    }

    private sealed class RouterForwarderFactory(UpstreamRouter router) : IForwarderHttpClientFactory
    {
        public HttpMessageInvoker CreateClient(ForwarderHttpClientContext context) => new(router.CreateHandler(), disposeHandler: true);
    }

    /// <summary>Creates a fresh synthetic auth user (as the DB owner) with optional memberships.</summary>
    public static async Task<Guid> CreateUserAsync(string label, params (Guid Tenant, Guid? Branch, string Role)[] memberships)
    {
        var id = Guid.NewGuid();
        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using (var cmd = new NpgsqlCommand("insert into auth.users (id, email) values (@id, @email)", conn))
        {
            cmd.Parameters.AddWithValue("id", id);
            cmd.Parameters.AddWithValue("email", $"{label}-{id:N}@synthetic.example");
            await cmd.ExecuteNonQueryAsync();
        }

        foreach (var (tenant, branch, role) in memberships)
        {
            await using var cmd = new NpgsqlCommand(
                "insert into identity.memberships (tenant_id, user_id, branch_id, role, status) values (@t, @u, @b, @r, 'active')", conn);
            cmd.Parameters.AddWithValue("t", tenant);
            cmd.Parameters.AddWithValue("u", id);
            cmd.Parameters.AddWithValue("b", (object?)branch ?? DBNull.Value);
            cmd.Parameters.AddWithValue("r", role);
            await cmd.ExecuteNonQueryAsync();
        }

        return id;
    }

    public static async Task<string> EmailOfAsync(Guid userId)
    {
        await using var conn = new NpgsqlConnection(AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand("select email from auth.users where id = @id", conn);
        cmd.Parameters.AddWithValue("id", userId);
        return (string)(await cmd.ExecuteScalarAsync())!;
    }

    private sealed class StubJwksHandler : HttpMessageHandler
    {
        public int Requests;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref Requests);
            if (request.RequestUri?.ToString() != $"{TestJwt.Issuer}/.well-known/jwks.json")
            {
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound));
            }

            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(TestJwt.JwksJson, Encoding.UTF8, "application/json"),
            });
        }
    }
}

/// <summary>Variant with the optional legacy HS256 secret configured.</summary>
public sealed class HmsApiFactoryWithLegacySecret : HmsApiFactory
{
    protected override string? LegacySecret => TestJwt.LegacySecret;
}
