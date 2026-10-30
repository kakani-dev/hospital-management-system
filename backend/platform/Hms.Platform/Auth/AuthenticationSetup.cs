using System.Text;
using Hms.Platform.Http;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;

namespace Hms.Platform.Auth;

public sealed class SupabaseAuthOptions
{
    public const string Section = "Auth:Supabase";
    public const string JwksHttpClient = "supabase-jwks";

    /// <summary>e.g. https://&lt;project-ref&gt;.supabase.co. Empty means every token is rejected.</summary>
    public string ProjectUrl { get; set; } = string.Empty;

    public string Audience { get; set; } = "authenticated";

    public const int DefaultJwksTimeoutSeconds = 10;

    /// <summary>JWKS fetch timeout (1-120 s). Read when the HTTP client is registered.</summary>
    public int JwksTimeoutSeconds { get; set; } = DefaultJwksTimeoutSeconds;

    /// <summary>How often the JWKS key set is refreshed in the background (5-1440 min).</summary>
    public int JwksAutomaticRefreshMinutes { get; set; } = 60;

    /// <summary>Minimum gap between refreshes forced by an unknown key id (1-3600 s).</summary>
    public int JwksRefreshSeconds { get; set; } = 60;

    /// <summary>Allowed token clock skew (0-300 s).</summary>
    public int ClockSkewSeconds { get; set; } = 30;

    /// <summary>
    /// OPTIONAL legacy HS256 JWT secret (Supabase "Legacy JWT secret"). Only for projects that
    /// still issue symmetric tokens. Leave empty to accept asymmetric (JWKS) tokens only.
    /// Supply via secret store / env var, never appsettings in git.
    /// </summary>
    public string? LegacyJwtSecret { get; set; }

    /// <summary>
    /// GoTrue service-role key used only to turn a checked invite sign-in code into a magic-link
    /// token hash. Supply via secret store / env (<c>Auth__Supabase__ServiceRoleKey</c>). Never
    /// commit it, log it, or put it in appsettings.
    /// </summary>
    public string ServiceRoleKey { get; set; } = "";

    /// <summary>
    /// Allow http:// JWKS (local mock auth / tests only). Only honoured in the environments listed in
    /// <see cref="AuthenticationSetup.InsecureHttpEnvironments"/>; startup fails anywhere else.
    /// </summary>
    public bool AllowInsecureHttp { get; set; }

    public string Issuer => $"{ProjectUrl.TrimEnd('/')}/auth/v1";

    public string JwksUrl => $"{Issuer}/.well-known/jwks.json";
}

/// <summary>
/// Remembers whether the last JWKS retrieval failed and turns the failure into an empty key set, so
/// JwtBearer reports "no signing keys" (IDX10500) and the bearer events answer 503 instead of 401/500.
/// </summary>
internal sealed class TrackingConfigurationManager(IConfigurationManager<OpenIdConnectConfiguration> inner)
    : IConfigurationManager<OpenIdConnectConfiguration>
{
    public volatile bool Unavailable;

    public async Task<OpenIdConnectConfiguration> GetConfigurationAsync(CancellationToken cancel)
    {
        try
        {
            var config = await inner.GetConfigurationAsync(cancel).ConfigureAwait(false);
            Unavailable = false;
            return config;
        }
#pragma warning disable CA1031 // any retrieval failure = key source unavailable; reported as 503 by the bearer events
        catch (Exception) when (!cancel.IsCancellationRequested)
#pragma warning restore CA1031
        {
            // No keys -> token validation fails with IDX10500, which OnAuthenticationFailed maps to 503
            // because Unavailable is set (instead of an unhandled 500 or a misleading 401).
            Unavailable = true;
            return new OpenIdConnectConfiguration();
        }
    }

    public void RequestRefresh() => inner.RequestRefresh();
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
    /// <summary>
    /// Environments where <see cref="SupabaseAuthOptions.AllowInsecureHttp"/> may be enabled. An
    /// allow-list (review Minor 7): Staging/Demo/any unknown name is refused, not just Production.
    /// "E2E" is the Playwright full-stack environment (tests/playwright/playwright.config.ts).
    /// </summary>
    public static readonly IReadOnlySet<string> InsecureHttpEnvironments =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Environments.Development, "Testing", "E2E" };

    public static bool IsInsecureHttpAllowed(IHostEnvironment environment) =>
        InsecureHttpEnvironments.Contains(environment.EnvironmentName);

    public static IServiceCollection AddHmsAuthentication(this IServiceCollection services, IConfiguration configuration, IHostEnvironment environment)
    {
        services.Configure<SupabaseAuthOptions>(configuration.GetSection(SupabaseAuthOptions.Section));
        services.AddHttpClient(SupabaseAuthOptions.JwksHttpClient, c => c.Timeout = TimeSpan.FromSeconds(Math.Clamp(
            configuration.GetValue($"{SupabaseAuthOptions.Section}:JwksTimeoutSeconds", SupabaseAuthOptions.DefaultJwksTimeoutSeconds), 1, 120)));

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

        if (options.AllowInsecureHttp && !IsInsecureHttpAllowed(environment))
        {
            throw new InvalidOperationException(
                $"Auth:Supabase:AllowInsecureHttp is only allowed in {string.Join("/", InsecureHttpEnvironments)} (current: '{environment.EnvironmentName}').");
        }

        var requireHttps = !(options.AllowInsecureHttp && IsInsecureHttpAllowed(environment));
        jwt.RequireHttpsMetadata = requireHttps;

        // JWKS (asymmetric ES256/RS256 signing keys). ConfigurationManager caches the key set and
        // JwtBearer requests a refresh when it sees an unknown "kid" (key rotation).
        var keySource = new TrackingConfigurationManager(new ConfigurationManager<OpenIdConnectConfiguration>(
            options.JwksUrl,
            new JwksConfigurationRetriever(options.Issuer),
            new HttpDocumentRetriever(httpClientFactory.CreateClient(SupabaseAuthOptions.JwksHttpClient)) { RequireHttps = requireHttps })
        {
            AutomaticRefreshInterval = TimeSpan.FromMinutes(Math.Clamp(options.JwksAutomaticRefreshMinutes, 5, 1440)),
            RefreshInterval = TimeSpan.FromSeconds(Math.Clamp(options.JwksRefreshSeconds, 1, 3600)),
        });
        jwt.ConfigurationManager = keySource;

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
            ClockSkew = TimeSpan.FromSeconds(Math.Clamp(options.ClockSkewSeconds, 0, 300)),
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

            // The signing keys could not be fetched (Supabase unreachable, cold start, DNS): that is an
            // outage, not a bad token. Answer 503 + Retry-After instead of 401, so the web app shows
            // "waking up / retrying" rather than pushing the user to sign in again.
            OnAuthenticationFailed = context =>
            {
                if (IsSigningKeySourceUnavailable(context.Exception)
                    || (keySource.Unavailable && context.Exception is SecurityTokenSignatureKeyNotFoundException))
                {
                    context.HttpContext.Items[SigningKeysUnavailableItem] = true;
                }

                return Task.CompletedTask;
            },
            OnChallenge = async context =>
            {
                if (context.HttpContext.Items.ContainsKey(SigningKeysUnavailableItem))
                {
                    context.HandleResponse();
                    await ServiceUnavailable.WriteAsync(
                        context.HttpContext, "The sign-in key service is unreachable. Retry shortly.").ConfigureAwait(false);
                }
            },
        };
    }

    internal const string SigningKeysUnavailableItem = "hms.auth.signing-keys-unavailable";

    /// <summary>
    /// True when JWT validation failed because the JWKS document could not be retrieved
    /// (IDX20803 "Unable to obtain configuration", or a transport error / timeout in the chain),
    /// as opposed to an invalid, expired or forged token.
    /// </summary>
    internal static bool IsSigningKeySourceUnavailable(Exception? exception)
    {
        for (var e = exception; e is not null; e = e.InnerException)
        {
            if (e is HttpRequestException or TaskCanceledException or TimeoutException or System.IO.IOException)
            {
                return true;
            }

            if (e is InvalidOperationException && e.Message.Contains("IDX20803", StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }
}
