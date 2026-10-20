using System.Text;
using Hms.Edge;
using Microsoft.AspNetCore.Http;

namespace Hms.IntegrationTests;

/// <summary>Edge conditional-GET middleware in isolation (no database).</summary>
public sealed class ReferenceETagTests
{
    private static DefaultHttpContext Request(string method, string path, string? ifNoneMatch = null, bool auth = true)
    {
        var ctx = new DefaultHttpContext();
        ctx.Request.Method = method;
        ctx.Request.Path = path;
        if (auth)
        {
            ctx.Request.Headers.Authorization = "Bearer x";
        }

        if (ifNoneMatch is not null)
        {
            ctx.Request.Headers.IfNoneMatch = ifNoneMatch;
        }

        ctx.Response.Body = new MemoryStream();
        return ctx;
    }

    private static RequestDelegate Upstream(string body, int status = 200) => async ctx =>
    {
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        await ctx.Response.WriteAsync(body);
    };

    private static string Body(HttpContext ctx)
    {
        ctx.Response.Body.Position = 0;
        return new StreamReader(ctx.Response.Body).ReadToEnd();
    }

    [Theory]
    [InlineData("GET", "/api/v1/branches", true, true)]
    [InlineData("GET", "/api/v1/me", true, true)]
    [InlineData("GET", "/api/v1/tenants/current", true, true)]
    [InlineData("GET", "/api/v1/practitioners", true, true)]
    [InlineData("GET", "/api/v1/patients", true, false)] // PHI: never
    [InlineData("GET", "/api/v1/queue", true, false)]
    [InlineData("GET", "/api/v1/slots", true, false)]
    [InlineData("POST", "/api/v1/branches", true, false)]
    [InlineData("GET", "/api/v1/branches", false, false)] // anonymous: never
    public void Applies_only_to_authenticated_reference_reads(string method, string path, bool auth, bool expected) =>
        Assert.Equal(expected, ReferenceETag.Applies(Request(method, path, auth: auth).Request));

    [Fact]
    public async Task First_read_gets_an_etag_and_a_private_revalidate_policy()
    {
        var ctx = Request("GET", "/api/v1/branches");
        await ReferenceETag.InvokeAsync(ctx, Upstream("[{\"id\":\"b1\"}]"));
        Assert.Equal(200, ctx.Response.StatusCode);
        Assert.Equal("[{\"id\":\"b1\"}]", Body(ctx));
        Assert.Equal(ReferenceETag.Compute(Encoding.UTF8.GetBytes("[{\"id\":\"b1\"}]")), ctx.Response.Headers.ETag.ToString());
        Assert.Equal("private, no-cache", ctx.Response.Headers.CacheControl.ToString());
        Assert.Contains("Authorization", ctx.Response.Headers.Vary.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_matching_if_none_match_gets_304_without_a_body()
    {
        var etag = ReferenceETag.Compute(Encoding.UTF8.GetBytes("[1]"));
        var ctx = Request("GET", "/api/v1/branches", $"W/{etag}");
        await ReferenceETag.InvokeAsync(ctx, Upstream("[1]"));
        Assert.Equal(304, ctx.Response.StatusCode);
        Assert.Equal(string.Empty, Body(ctx));
    }

    [Fact]
    public async Task Changed_data_gets_a_new_etag_and_the_full_body()
    {
        var old = ReferenceETag.Compute(Encoding.UTF8.GetBytes("[1]"));
        var ctx = Request("GET", "/api/v1/branches", old);
        await ReferenceETag.InvokeAsync(ctx, Upstream("[1,2]"));
        Assert.Equal(200, ctx.Response.StatusCode);
        Assert.Equal("[1,2]", Body(ctx));
        Assert.NotEqual(old, ctx.Response.Headers.ETag.ToString());
    }

    [Fact]
    public async Task Errors_and_non_reference_paths_pass_through_untouched()
    {
        var error = Request("GET", "/api/v1/branches", "*");
        await ReferenceETag.InvokeAsync(error, Upstream("{\"status\":403}", 403));
        Assert.Equal(403, error.Response.StatusCode);
        Assert.Equal("{\"status\":403}", Body(error));
        Assert.False(error.Response.Headers.ContainsKey("ETag"));

        var phi = Request("GET", "/api/v1/patients", "*");
        await ReferenceETag.InvokeAsync(phi, Upstream("[]"));
        Assert.Equal(200, phi.Response.StatusCode);
        Assert.False(phi.Response.Headers.ContainsKey("ETag"));
    }
}
