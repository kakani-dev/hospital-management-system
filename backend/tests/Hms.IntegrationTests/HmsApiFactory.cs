using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Hms.Gateway.Infrastructure;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;

namespace Hms.IntegrationTests;

/// <summary>
/// Gateway host against the REAL PostgreSQL database prepared by supabase/scripts/run-sql-tests.sh
/// (migrations + synthetic seed), connecting as the low-privilege hms_api_login role, with real
/// JWT bearer validation against a fake JWKS endpoint.
/// </summary>
public class HmsApiFactory : WebApplicationFactory<Program>
{
    public static readonly string ApiConnection =
        Environment.GetEnvironmentVariable("HMS_API_TEST_CONNECTION")
        ?? "Host=localhost;Port=5432;Database=hms_sql_test;Username=hms_api_login;Password=hms_api_local_only";

    public static readonly string AdminConnection =
        Environment.GetEnvironmentVariable("HMS_DB_TEST_CONNECTION")
        ?? "Host=localhost;Port=5432;Database=hms_sql_test;Username=postgres;Password=postgres";

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

    public int JwksRequests => _jwks.Requests;

    private readonly StubJwksHandler _jwks = new();

    protected virtual string? LegacySecret => null;

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.UseSetting("ConnectionStrings:HmsDatabase", ApiConnection);
        builder.UseSetting("Auth:Supabase:ProjectUrl", TestJwt.ProjectUrl);
        builder.UseSetting("Auth:Supabase:LegacyJwtSecret", LegacySecret ?? string.Empty);
        builder.UseSetting("RateLimiting:PermitPerMinute", "100000");
        builder.ConfigureTestServices(services =>
            services.AddHttpClient(SupabaseAuthOptions.JwksHttpClient).ConfigurePrimaryHttpMessageHandler(() => _jwks));
    }

    public HttpClient ClientWithToken(string token)
    {
        var client = CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client;
    }

    /// <summary>Token for a user; tenant claim as the custom access token hook would issue it.</summary>
    public HttpClient ClientAs(Guid user, Guid? tenant = null, Guid? branch = null)
    {
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
