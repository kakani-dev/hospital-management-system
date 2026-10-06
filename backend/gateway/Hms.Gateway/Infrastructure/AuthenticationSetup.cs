using System.Text;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;

namespace Hms.Gateway.Infrastructure;

public sealed class SupabaseAuthOptions
{
    public const string Section = "Auth:Supabase";
    public const string JwksHttpClient = "supabase-jwks";

    /// <summary>e.g. https://&lt;project-ref&gt;.supabase.co. Empty means every token is rejected.</summary>
    public string ProjectUrl { get; set; } = string.Empty;

    public string Audience { get; set; } = "authenticated";

    /// <summary>
    /// OPTIONAL legacy HS256 JWT secret (Supabase "Legacy JWT secret"). Only for projects that
    /// still issue symmetric tokens. Leave empty to accept asymmetric (JWKS) tokens only.
    /// Supply via secret store / env var, never appsettings in git.
    /// </summary>
    public string? LegacyJwtSecret { get; set; }

    /// <summary>Allow http:// JWKS (local mock auth / tests only). Refused in Production.</summary>
    public bool AllowInsecureHttp { get; set; }

    public string Issuer => $"{ProjectUrl.TrimEnd('/')}/auth/v1";

    public string JwksUrl => $"{Issuer}/.well-known/jwks.json";
}

/// <summary>Fetches a bare JWKS document and exposes it as OIDC configuration for JwtBearer.</summary>
internal sealed class JwksConfigurationRetriever(string issuer) : IConfigurationRetriever<OpenIdConnectConfiguration>
{
    public async Task<OpenIdConnectConfiguration> GetConfigurationAsync(string address, IDocumentRetriever retriever, CancellationToken cancel)
    {
        var json = await retriever.GetDocumentAsync(address, cancel).ConfigureAwait(false);
        var jwks = new JsonWebKeySet(json);
        var config = new OpenIdConnectConfiguration { Issuer = issuer, JwksUri = address, JsonWebKeySet = jwks };
        foreach (var key in jwks.GetSigningKeys())
        {
            config.SigningKeys.Add(key);
        }

        return config;
    }
}

public static class AuthenticationSetup
{
    public static IServiceCollection AddHmsAuthentication(this IServiceCollection services, IConfiguration configuration, IHostEnvironment environment)
    {
        services.Configure<SupabaseAuthOptions>(configuration.GetSection(SupabaseAuthOptions.Section));
        services.AddHttpClient(SupabaseAuthOptions.JwksHttpClient, c => c.Timeout = TimeSpan.FromSeconds(10));

        services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer();
        services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
            .Configure<IOptions<SupabaseAuthOptions>, IHttpClientFactory>((jwt, supabaseOptions, httpClientFactory) =>
                Configure(jwt, supabaseOptions.Value, httpClientFactory, environment));

        services.AddAuthorization();
        return services;
    }

    internal static void Configure(JwtBearerOptions jwt, SupabaseAuthOptions options, IHttpClientFactory httpClientFactory, IHostEnvironment environment)
    {
        // Keep raw claim names ("sub", "app_metadata", "tenant_id", ...) instead of WS-* URIs.
        jwt.MapInboundClaims = false;

        if (string.IsNullOrWhiteSpace(options.ProjectUrl))
        {
            // Fail closed: no keys, impossible issuer => every token is rejected.
            jwt.TokenValidationParameters = new TokenValidationParameters
            {
                ValidIssuer = "unconfigured",
                ValidAudience = "unconfigured",
                IssuerSigningKeys = [],
            };
            return;
        }

        if (options.AllowInsecureHttp && environment.IsProduction())
        {
            throw new InvalidOperationException("Auth:Supabase:AllowInsecureHttp must not be enabled in Production.");
        }

        var requireHttps = !options.AllowInsecureHttp;
        jwt.RequireHttpsMetadata = requireHttps;

        // JWKS (asymmetric ES256/RS256 signing keys). ConfigurationManager caches the key set and
        // JwtBearer requests a refresh when it sees an unknown "kid" (key rotation).
        jwt.ConfigurationManager = new ConfigurationManager<OpenIdConnectConfiguration>(
            options.JwksUrl,
            new JwksConfigurationRetriever(options.Issuer),
            new HttpDocumentRetriever(httpClientFactory.CreateClient(SupabaseAuthOptions.JwksHttpClient)) { RequireHttps = requireHttps })
        {
            AutomaticRefreshInterval = TimeSpan.FromHours(1),
            RefreshInterval = TimeSpan.FromMinutes(1),
        };

        var algorithms = new List<string> { SecurityAlgorithms.EcdsaSha256, SecurityAlgorithms.RsaSha256 };
        var legacyKeys = new List<SecurityKey>();
        if (!string.IsNullOrWhiteSpace(options.LegacyJwtSecret))
        {
            algorithms.Add(SecurityAlgorithms.HmacSha256);
            legacyKeys.Add(new SymmetricSecurityKey(Encoding.UTF8.GetBytes(options.LegacyJwtSecret)));
        }

        jwt.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = options.Issuer,
            ValidateAudience = true,
            ValidAudience = options.Audience,
            ValidateLifetime = true,
            RequireExpirationTime = true,
            RequireSignedTokens = true,
            ValidateIssuerSigningKey = true,
            ValidAlgorithms = algorithms,
            IssuerSigningKeys = legacyKeys, // JwtBearer appends the JWKS keys from ConfigurationManager
            ClockSkew = TimeSpan.FromSeconds(30),
            NameClaimType = "sub",
            RoleClaimType = "role",
        };

        jwt.Events = new JwtBearerEvents
        {
            // Only end-user sessions may call the API: reject anon/service_role keys and subject-less tokens.
            OnTokenValidated = context =>
            {
                var principal = context.Principal;
                var role = principal?.FindFirst("role")?.Value;
                var sub = principal?.FindFirst("sub")?.Value;
                if (role != "authenticated" || !Guid.TryParse(sub, out _))
                {
                    context.Fail("Only authenticated user tokens are accepted.");
                }

                return Task.CompletedTask;
            },
        };
    }
}
