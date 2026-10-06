using Hms.Gateway.Infrastructure;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.FileProviders;
using Microsoft.IdentityModel.Tokens;

namespace Hms.UnitTests;

public class AuthenticationSetupTests
{
    private sealed class Env(string name) : IHostEnvironment
    {
        public string EnvironmentName { get; set; } = name;
        public string ApplicationName { get; set; } = "Hms.Gateway";
        public string ContentRootPath { get; set; } = AppContext.BaseDirectory;
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }

    private sealed class Factory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new();
    }

    private static JwtBearerOptions Configure(SupabaseAuthOptions options, string env = "Development")
    {
        var jwt = new JwtBearerOptions();
        AuthenticationSetup.Configure(jwt, options, new Factory(), new Env(env));
        return jwt;
    }

    [Fact]
    public void Unconfigured_project_fails_closed()
    {
        var jwt = Configure(new SupabaseAuthOptions());
        Assert.Null(jwt.ConfigurationManager);
        Assert.Empty(jwt.TokenValidationParameters.IssuerSigningKeys);
        Assert.Equal("unconfigured", jwt.TokenValidationParameters.ValidIssuer);
    }

    [Fact]
    public void Configured_project_validates_issuer_audience_lifetime_and_uses_jwks()
    {
        var jwt = Configure(new SupabaseAuthOptions { ProjectUrl = "https://abc.supabase.co/" });
        var p = jwt.TokenValidationParameters;
        Assert.Equal("https://abc.supabase.co/auth/v1", p.ValidIssuer);
        Assert.Equal("authenticated", p.ValidAudience);
        Assert.True(p.ValidateIssuer && p.ValidateAudience && p.ValidateLifetime && p.RequireSignedTokens && p.RequireExpirationTime);
        Assert.NotNull(jwt.ConfigurationManager);
        Assert.True(jwt.RequireHttpsMetadata);
        Assert.False(jwt.MapInboundClaims);
        Assert.DoesNotContain(SecurityAlgorithms.HmacSha256, p.ValidAlgorithms);
        Assert.Contains(SecurityAlgorithms.EcdsaSha256, p.ValidAlgorithms);
    }

    [Fact]
    public void Hs256_is_only_accepted_with_a_legacy_secret()
    {
        var jwt = Configure(new SupabaseAuthOptions { ProjectUrl = "https://abc.supabase.co", LegacyJwtSecret = "0123456789abcdef0123456789abcdef" });
        Assert.Contains(SecurityAlgorithms.HmacSha256, jwt.TokenValidationParameters.ValidAlgorithms);
        Assert.Single(jwt.TokenValidationParameters.IssuerSigningKeys);
    }

    [Theory]
    [InlineData("Production")]
    [InlineData("Staging")]
    [InlineData("Demo")]
    [InlineData("")]
    public void Insecure_http_is_refused_outside_dev_and_test_environments(string env) =>
        Assert.Throws<InvalidOperationException>(() =>
            Configure(new SupabaseAuthOptions { ProjectUrl = "http://localhost:54321", AllowInsecureHttp = true }, env));

    [Theory]
    [InlineData("Development")]
    [InlineData("Testing")]
    [InlineData("E2E")]
    public void Insecure_http_is_allowed_for_local_mock_auth(string env)
    {
        var jwt = Configure(new SupabaseAuthOptions { ProjectUrl = "http://localhost:54321", AllowInsecureHttp = true }, env);
        Assert.False(jwt.RequireHttpsMetadata);
        Assert.Equal("http://localhost:54321/auth/v1", jwt.TokenValidationParameters.ValidIssuer);
    }

    [Theory]
    [InlineData("Production")]
    [InlineData("Staging")]
    [InlineData("Development")]
    public void Https_is_required_when_insecure_http_is_not_requested(string env) =>
        Assert.True(Configure(new SupabaseAuthOptions { ProjectUrl = "https://abc.supabase.co" }, env).RequireHttpsMetadata);

    [Fact]
    public void Jwks_url_is_derived_from_project_url() =>
        Assert.Equal("https://abc.supabase.co/auth/v1/.well-known/jwks.json", new SupabaseAuthOptions { ProjectUrl = "https://abc.supabase.co" }.JwksUrl);
}
