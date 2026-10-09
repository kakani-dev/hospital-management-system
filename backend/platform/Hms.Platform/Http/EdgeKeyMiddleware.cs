using System.Security.Cryptography;
using System.Text;

namespace Hms.Platform.Http;

/// <summary>
/// Defence in depth behind the YARP edge (docs/architecture/microservices.md §6). On Azure Container
/// Apps the services have INTERNAL ingress, so only the edge can reach them; in addition, when
/// <c>Edge:Key</c> is configured, every request except <c>/health/*</c> must carry
/// <c>X-Hms-Edge-Key</c> with that value. Anything else gets a bare 404 (the service does not admit
/// to existing). The edge strips any client-supplied <c>X-Hms-*</c> header before adding the key.
/// Empty <c>Edge:Key</c> (local dev, in-process tests of a single service) disables the check.
/// </summary>
public static class EdgeKeyMiddleware
{
    public const string Header = "X-Hms-Edge-Key";
    public const string ConfigKey = "Edge:Key";

    public static IApplicationBuilder UseHmsEdgeKey(this IApplicationBuilder app, IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var key = configuration[ConfigKey];
        if (string.IsNullOrEmpty(key))
        {
            return app;
        }

        var expected = Encoding.UTF8.GetBytes(key);
        return app.Use(async (context, next) =>
        {
            if (context.Request.Path.StartsWithSegments("/health", StringComparison.OrdinalIgnoreCase) || Matches(context, expected))
            {
                await next(context).ConfigureAwait(false);
                return;
            }

            context.Response.StatusCode = StatusCodes.Status404NotFound;
        });
    }

    private static bool Matches(HttpContext context, byte[] expected)
    {
        var values = context.Request.Headers[Header];
        if (values.Count != 1 || string.IsNullOrEmpty(values[0]))
        {
            return false;
        }

        return CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(values[0]!), expected);
    }
}
