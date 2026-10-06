using System.Net;
using System.Net.Http.Json;

namespace Hms.IntegrationTests;

public class HealthEndpointTests(HmsApiFactory factory) : IClassFixture<HmsApiFactory>
{
    private sealed record HealthDto(string Status);

    [Theory]
    [InlineData("/health/live")]
    [InlineData("/health/ready")]
    public async Task Health_endpoints_are_anonymous_and_healthy(string path)
    {
        using var client = factory.CreateClient();
        var response = await client.GetAsync(path);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("Healthy", (await response.Content.ReadFromJsonAsync<HealthDto>())!.Status);
        Assert.Equal("nosniff", response.Headers.GetValues("X-Content-Type-Options").Single());
    }

    [Fact]
    public async Task OpenApi_document_is_not_exposed_outside_development()
    {
        using var client = factory.CreateClient();
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/openapi/v1.json")).StatusCode);
    }
}
