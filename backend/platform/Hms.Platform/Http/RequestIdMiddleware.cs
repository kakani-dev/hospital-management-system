using System.Text.RegularExpressions;
using Serilog.Context;

namespace Hms.Platform.Http;

/// <summary>
/// Correlation id shared by the edge and the services: <c>X-Request-Id</c> is accepted when it is a
/// short safe token (the edge always sends one), otherwise a new one is generated. It becomes the
/// ASP.NET trace identifier (so ProblemDetails <c>traceId</c> matches), is pushed to the log context and
/// is echoed on the response so the web app can show "Ref: ...".
/// </summary>
public static partial class RequestIdMiddleware
{
    public const string Header = "X-Request-Id";

    public static IApplicationBuilder UseHmsRequestId(this IApplicationBuilder app) =>
        app.Use(async (context, next) =>
        {
            var id = Resolve(context.Request.Headers[Header].ToString());
            context.TraceIdentifier = id;
            context.Request.Headers[Header] = id;
            context.Response.OnStarting(() =>
            {
                context.Response.Headers[Header] = id;
                return Task.CompletedTask;
            });
            using (LogContext.PushProperty("RequestId", id))
            {
                await next(context).ConfigureAwait(false);
            }
        });

    public static string Resolve(string? incoming) =>
        !string.IsNullOrEmpty(incoming) && SafeId().IsMatch(incoming) ? incoming : Guid.NewGuid().ToString("N");

    [GeneratedRegex("^[A-Za-z0-9._:-]{1,64}$", RegexOptions.CultureInvariant)]
    private static partial Regex SafeId();
}
