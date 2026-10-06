using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;

namespace Hms.Gateway.Infrastructure;

public sealed class SupabaseAuthOptions
{
    public const string Section = "Auth:Supabase";

    /// <summary>e.g. https://&lt;project-ref&gt;.supabase.co — empty means "reject every token".</summary>
    public string ProjectUrl { get; set; } = string.Empty;

    public string Audience { get; set; } = "authenticated";
}

public static class AuthenticationSetup
{
    public static IServiceCollection AddHmsAuthentication(this IServiceCollection services, IConfiguration configuration)
    {
        var options = configuration.GetSection(SupabaseAuthOptions.Section).Get<SupabaseAuthOptions>() ?? new SupabaseAuthOptions();

        services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(jwt =>
            {
                // Keep raw claim names ("sub", "app_metadata", ...) instead of WS-* URIs.
                jwt.MapInboundClaims = false;

                if (string.IsNullOrWhiteSpace(options.ProjectUrl))
                {
                    // Fail closed: no signing keys and no issuer => every token is rejected.
                    jwt.TokenValidationParameters = new TokenValidationParameters
                    {
                        ValidateIssuer = true,
                        ValidIssuer = "unconfigured",
                        ValidateAudience = true,
                        ValidAudience = "unconfigured",
                        IssuerSigningKeys = [],
                    };
                    return;
                }

                // TODO(Sprint 1, SECURITY): finish Supabase JWT validation and test it against a real project:
                //   * Supabase asymmetric signing keys are published at {ProjectUrl}/auth/v1/.well-known/jwks.json;
                //     confirm OIDC metadata discovery works for the Authority below, otherwise set
                //     IssuerSigningKeyResolver from the JWKS endpoint explicitly (cached + rotated).
                //   * Do NOT accept the legacy shared HS256 secret in production.
                //   * Validate "role" == "authenticated" and reject anon/service_role tokens on user endpoints.
                //   * Add a custom access token hook that writes tenant_id/branch_id claims server-side.
                var issuer = $"{options.ProjectUrl.TrimEnd('/')}/auth/v1";
                jwt.Authority = issuer;
                jwt.RequireHttpsMetadata = true;
                jwt.TokenValidationParameters = new TokenValidationParameters
                {
                    ValidateIssuer = true,
                    ValidIssuer = issuer,
                    ValidateAudience = true,
                    ValidAudience = options.Audience,
                    ValidateLifetime = true,
                    ClockSkew = TimeSpan.FromSeconds(30),
                    NameClaimType = "sub",
                    RoleClaimType = "role",
                };
            });

        services.AddAuthorization();
        return services;
    }
}
