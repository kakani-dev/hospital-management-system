using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Hms.IntegrationTests;

/// <summary>
/// TEST-ONLY authentication: simulates an already-validated Supabase JWT by turning
/// X-Test-* headers into claims. Exists only in this test assembly, never in the gateway.
/// </summary>
public sealed class TestAuthHandler(IOptionsMonitor<AuthenticationSchemeOptions> options, ILoggerFactory logger, UrlEncoder encoder)
    : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    public const string SchemeName = "Test";
    public const string SubHeader = "X-Test-Sub";
    public const string TenantHeader = "X-Test-Claim-Tenant";
    public const string BranchHeader = "X-Test-Claim-Branch";

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!Request.Headers.TryGetValue(SubHeader, out var sub))
        {
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        var claims = new List<Claim> { new("sub", sub.ToString()), new("role", "authenticated") };
        if (Request.Headers.TryGetValue(TenantHeader, out var tenant))
        {
            claims.Add(new Claim("app_metadata", $$"""{"tenant_id":"{{tenant}}"}"""));
        }

        if (Request.Headers.TryGetValue(BranchHeader, out var branch))
        {
            claims.Add(new Claim("branch_id", branch.ToString()));
        }

        var principal = new ClaimsPrincipal(new ClaimsIdentity(claims, SchemeName));
        return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(principal, SchemeName)));
    }
}
