using System.Security.Cryptography;
using Microsoft.Net.Http.Headers;

namespace Hms.Edge;

/// <summary>
/// Conditional GETs for safe, authenticated reference reads (identity, branches, practitioners,
/// schedules, hospital settings). The edge hashes the upstream 200 body into a strong ETag and
/// answers <c>If-None-Match</c> with 304 (no body), and marks the response
/// <c>private, no-cache</c> + <c>Vary: Authorization, X-Branch-Id</c>: browsers may keep it per user
/// but must revalidate every time, and shared caches never store it. The tag is derived from the
/// caller's own response body, so a 304 only ever confirms data that caller was already sent;
/// nothing is shared across users or tenants. Everything else under /api stays <c>no-store</c>.
/// </summary>
public static class ReferenceETag
{
    /// <summary>Upper bound for buffering a body to hash it; larger responses pass through untouched.</summary>
    public const int MaxBufferedBytes = 512 * 1024;

    public const string CacheControlValue = "private, no-cache";

    private static readonly string[] Paths =
    [
        "/api/v1/me",
        "/api/v1/tenants/current",
        "/api/v1/branches",
        "/api/v1/practitioners",
        "/api/v1/schedules",
        "/api/v1/practitioner-branches",
        "/api/v1/schedule-overrides",
        "/api/v1/scheduling-settings",
        "/api/v1/reminders/settings",
    ];

    public static bool Applies(HttpRequest request) =>
        (HttpMethods.IsGet(request.Method) || HttpMethods.IsHead(request.Method))
        && request.Headers.Authorization.Count > 0
        && Paths.Any(p => request.Path.Equals(p, StringComparison.OrdinalIgnoreCase));

    public static string Compute(ReadOnlySpan<byte> body) =>
        $"\"{Convert.ToHexString(SHA256.HashData(body))[..32].ToLowerInvariant()}\"";

    public static bool Matches(string? ifNoneMatch, string etag)
    {
        if (string.IsNullOrWhiteSpace(ifNoneMatch))
        {
            return false;
        }

        foreach (var candidate in ifNoneMatch.Split(','))
        {
            var tag = candidate.Trim();
            if (tag.StartsWith("W/", StringComparison.Ordinal))
            {
                tag = tag[2..];
            }

            if (tag == "*" || string.Equals(tag, etag, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    public static async Task InvokeAsync(HttpContext context, RequestDelegate next)
    {
        if (!Applies(context.Request))
        {
            await next(context).ConfigureAwait(false);
            return;
        }

        var original = context.Response.Body;
        using var buffer = new MemoryStream();
        context.Response.Body = buffer;
        try
        {
            await next(context).ConfigureAwait(false);
        }
        finally
        {
            context.Response.Body = original;
        }

        var response = context.Response;
        if (response.StatusCode == StatusCodes.Status200OK && buffer.Length <= MaxBufferedBytes)
        {
            var etag = Compute(buffer.GetBuffer().AsSpan(0, (int)buffer.Length));
            response.Headers.ETag = etag;
            response.Headers.CacheControl = CacheControlValue;
            response.Headers.Append(HeaderNames.Vary, "Authorization, X-Branch-Id");
            if (Matches(context.Request.Headers.IfNoneMatch, etag))
            {
                response.StatusCode = StatusCodes.Status304NotModified;
                response.ContentLength = null;
                response.Headers.Remove(HeaderNames.ContentLength);
                response.Headers.Remove(HeaderNames.ContentType);
                return;
            }
        }

        if (buffer.Length > 0)
        {
            buffer.Position = 0;
            await buffer.CopyToAsync(original, context.RequestAborted).ConfigureAwait(false);
        }
    }
}
