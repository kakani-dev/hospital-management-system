using System.Net;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

[Trait("Category", "Database")]
public sealed class JwtValidationTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private async Task<HttpStatusCode> MeStatus(string token)
    {
        using var client = factory.ClientWithToken(token);
        return (await client.GetAsync("/api/v1/me")).StatusCode;
    }

    [Fact]
    public async Task Valid_es256_token_from_jwks_is_accepted() =>
        Assert.Equal(HttpStatusCode.OK, await MeStatus(TestJwt.Create(AlphaAdmin)));

    [Fact]
    public async Task Missing_token_is_401()
    {
        using var client = factory.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/v1/me")).StatusCode);
    }

    [Fact]
    public async Task Expired_token_is_rejected() =>
        Assert.Equal(HttpStatusCode.Unauthorized, await MeStatus(TestJwt.Create(AlphaAdmin, expires: DateTime.UtcNow.AddMinutes(-5))));

    [Fact]
    public async Task Wrong_issuer_is_rejected() =>
        Assert.Equal(HttpStatusCode.Unauthorized, await MeStatus(TestJwt.Create(AlphaAdmin, issuer: "https://evil.supabase.co/auth/v1")));

    [Fact]
    public async Task Wrong_audience_is_rejected() =>
        Assert.Equal(HttpStatusCode.Unauthorized, await MeStatus(TestJwt.Create(AlphaAdmin, audience: "anon")));

    [Fact]
    public async Task Token_signed_with_unknown_private_key_but_known_kid_is_rejected() =>
        Assert.Equal(HttpStatusCode.Unauthorized, await MeStatus(TestJwt.Create(AlphaAdmin, key: TestJwt.RogueKey)));

    [Fact]
    public async Task Unsigned_alg_none_token_is_rejected() =>
        Assert.Equal(HttpStatusCode.Unauthorized, await MeStatus(TestJwt.AlgNone(AlphaAdmin)));

    [Fact]
    public async Task Hs256_token_is_rejected_when_no_legacy_secret_is_configured() =>
        Assert.Equal(HttpStatusCode.Unauthorized, await MeStatus(TestJwt.Hs256(AlphaAdmin)));

    [Theory]
    [InlineData("anon")]
    [InlineData("service_role")]
    public async Task Non_user_roles_are_rejected_even_if_signed(string role) =>
        Assert.Equal(HttpStatusCode.Unauthorized, await MeStatus(TestJwt.Create(AlphaAdmin, role: role)));

    [Fact]
    public async Task Jwks_is_cached_across_requests()
    {
        for (var i = 0; i < 3; i++)
        {
            Assert.Equal(HttpStatusCode.OK, await MeStatus(TestJwt.Create(AlphaAdmin)));
        }

        Assert.InRange(factory.JwksRequests, 1, 2);
    }
}

[Trait("Category", "Database")]
public sealed class LegacyHs256Tests(HmsApiFactoryWithLegacySecret factory) : IClassFixture<HmsApiFactoryWithLegacySecret>
{
    [Fact]
    public async Task Hs256_token_is_accepted_when_legacy_secret_is_configured_and_es256_still_works()
    {
        using var legacy = factory.ClientWithToken(TestJwt.Hs256(AlphaAdmin));
        Assert.Equal(HttpStatusCode.OK, (await legacy.GetAsync("/api/v1/me")).StatusCode);
        using var modern = factory.ClientWithToken(TestJwt.Create(AlphaAdmin));
        Assert.Equal(HttpStatusCode.OK, (await modern.GetAsync("/api/v1/me")).StatusCode);
    }
}
