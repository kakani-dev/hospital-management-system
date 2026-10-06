using System.Net;

namespace Hms.IntegrationTests;

[Trait("Category", "Database")]
public sealed class HealthAndSurfaceTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    [Fact]
    public async Task Liveness_is_public()
    {
        using var client = factory.CreateClient();
        var response = await client.GetAsync("/health/live");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task Readiness_reaches_the_database_as_the_api_role()
    {
        using var client = factory.CreateClient();
        var response = await client.GetAsync("/health/ready");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task Security_headers_are_present()
    {
        using var client = factory.CreateClient();
        var response = await client.GetAsync("/health/live");
        Assert.Equal("nosniff", response.Headers.GetValues("X-Content-Type-Options").Single());
        Assert.Equal("DENY", response.Headers.GetValues("X-Frame-Options").Single());
    }

    [Theory]
    [InlineData("/api/v1/patients")]
    [InlineData("/api/v1/branches")]
    [InlineData("/api/v1/members")]
    [InlineData("/api/v1/tenants/current")]
    [InlineData("/api/v1/me/invitations")]
    public async Task Api_requires_authentication(string path)
    {
        using var client = factory.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync(path)).StatusCode);
    }
}
