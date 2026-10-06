using System.IdentityModel.Tokens.Jwt;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.IdentityModel.Tokens;

namespace Hms.IntegrationTests;

/// <summary>Issues Supabase-shaped test JWTs signed with a throwaway ES256 key served by a fake JWKS.</summary>
public static class TestJwt
{
    public const string ProjectUrl = "https://hms-test.supabase.local";
    public const string Issuer = ProjectUrl + "/auth/v1";
    public const string Kid = "test-es256-key";
    public const string LegacySecret = "integration-test-legacy-hs256-secret-0123456789";

    private static readonly ECDsa SigningEcdsa = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    private static readonly ECDsa RogueEcdsa = ECDsa.Create(ECCurve.NamedCurves.nistP256);

    public static ECDsaSecurityKey SigningKey { get; } = new(SigningEcdsa) { KeyId = Kid };

    /// <summary>Same kid, different private key: must fail signature validation.</summary>
    public static ECDsaSecurityKey RogueKey { get; } = new(RogueEcdsa) { KeyId = Kid };

    public static string JwksJson
    {
        get
        {
            var p = SigningEcdsa.ExportParameters(false);
            var jwk = new Dictionary<string, object>
            {
                ["kty"] = "EC", ["crv"] = "P-256", ["alg"] = "ES256", ["use"] = "sig", ["kid"] = Kid,
                ["x"] = Base64UrlEncoder.Encode(p.Q.X), ["y"] = Base64UrlEncoder.Encode(p.Q.Y),
            };
            return JsonSerializer.Serialize(new { keys = new[] { jwk } });
        }
    }

    public static string Create(
        Guid sub,
        IDictionary<string, object>? extraClaims = null,
        string issuer = Issuer,
        string audience = "authenticated",
        string role = "authenticated",
        DateTime? expires = null,
        SecurityKey? key = null)
    {
        var claims = new Dictionary<string, object>
        {
            ["sub"] = sub.ToString(),
            ["role"] = role,
            ["email"] = $"{sub:N}@test.example",
            ["aal"] = "aal1",
        };
        foreach (var (k, v) in extraClaims ?? new Dictionary<string, object>())
        {
            claims[k] = v;
        }

        var signingKey = key ?? SigningKey;
        var algorithm = signingKey is SymmetricSecurityKey ? SecurityAlgorithms.HmacSha256 : SecurityAlgorithms.EcdsaSha256;
        var now = DateTime.UtcNow;
        var descriptor = new SecurityTokenDescriptor
        {
            Issuer = issuer,
            Audience = audience,
            Claims = claims,
            IssuedAt = expires is { } e && e < now ? e.AddMinutes(-10) : now,
            NotBefore = expires is { } e2 && e2 < now ? e2.AddMinutes(-10) : now,
            Expires = expires ?? now.AddMinutes(10),
            SigningCredentials = new SigningCredentials(signingKey, algorithm),
        };
        return new JwtSecurityTokenHandler().CreateEncodedJwt(descriptor);
    }

    public static string Hs256(Guid sub, IDictionary<string, object>? extraClaims = null) =>
        Create(sub, extraClaims, key: new SymmetricSecurityKey(Encoding.UTF8.GetBytes(LegacySecret)));

    /// <summary>An unsigned token ("alg":"none") — must always be rejected.</summary>
    public static string AlgNone(Guid sub)
    {
        static string B64(object o) => Base64UrlEncoder.Encode(JsonSerializer.Serialize(o));
        var exp = DateTimeOffset.UtcNow.AddMinutes(10).ToUnixTimeSeconds();
        return $"{B64(new { alg = "none", typ = "JWT" })}.{B64(new { sub = sub.ToString(), role = "authenticated", aud = "authenticated", iss = Issuer, exp })}.";
    }
}
