using System.Text.Json;
using Microsoft.AspNetCore.Http;

namespace Hms.Platform.Http;

/// <summary>
/// The one "try again shortly" contract shared by the YARP edge and every service
/// (docs/architecture/microservices.md §6): RFC 7807 problem+json with a machine-readable
/// <c>code</c>, plus <c>Retry-After</c> so the web client backs off instead of signing the user out.
/// </summary>
public static class ServiceUnavailable
{
    public const string Code = "service_unavailable";
    public const string UpstreamTimeoutCode = "upstream_timeout";
    public const int RetryAfterSeconds = 5;

    public static async Task WriteAsync(
        HttpContext context, string detail, int status = StatusCodes.Status503ServiceUnavailable, string code = Code)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (context.Response.HasStarted)
        {
            return;
        }

        context.Response.StatusCode = status;
        context.Response.Headers.RetryAfter = RetryAfterSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
        context.Response.Headers.CacheControl = "no-store";
        context.Response.ContentType = "application/problem+json";
        var problem = new Dictionary<string, object?>
        {
            ["type"] = "https://tools.ietf.org/html/rfc9110#section-15.6.4",
            ["title"] = status == StatusCodes.Status504GatewayTimeout ? "Upstream timeout" : "Service unavailable",
            ["status"] = status,
            ["detail"] = detail,
            ["code"] = code,
            ["traceId"] = context.TraceIdentifier,
        };
        await context.Response.WriteAsync(JsonSerializer.Serialize(problem, JsonSerializerOptions.Web), context.RequestAborted).ConfigureAwait(false);
    }
}
