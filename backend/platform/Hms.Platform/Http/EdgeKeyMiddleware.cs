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
/// Zero-downtime key rotation (issue #68, docs/runbooks/credential-rotation.md): services also
/// accept <c>Edge:PreviousKey</c> when it is set, so they can roll onto a new key before the edge
/// starts sending it. Only the edge sends a key, and it always sends <c>Edge:Key</c>. Retire the
/// previous key by setting it equal to the current one.
/// </summary>
public static class EdgeKeyMiddleware
{
    public const string Header = "X-Hms-Edge-Key";
    public const string ConfigKey = "Edge:Key";
    public const string PreviousConfigKey = "Edge:PreviousKey";

    public static IApplicationBuilder UseHmsEdgeKey(this IApplicationBuilder app, IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var key = configuration[ConfigKey];
        if (string.IsNullOrEmpty(key))
        {
            return app;
        }

        var accepted = AcceptedKeys(key, configuration[PreviousConfigKey]);
        return app.Use(async (context, next) =>
        {
            if (context.Request.Path.StartsWithSegments("/health", StringComparison.OrdinalIgnoreCase) || Matches(context.Request.Headers[Header], accepted))
            {
                await next(context).ConfigureAwait(false);
                return;
            }

            context.Response.StatusCode = StatusCodes.Status404NotFound;
        });
    }

    /// <summary>The current key, plus the previous key when it is set and different.</summary>
    public static IReadOnlyList<byte[]> AcceptedKeys(string key, string? previousKey)
    {
        var keys = new List<byte[]> { Encoding.UTF8.GetBytes(key) };
        if (!string.IsNullOrEmpty(previousKey) && !string.Equals(previousKey, key, StringComparison.Ordinal))
        {
            keys.Add(Encoding.UTF8.GetBytes(previousKey));
        }

        return keys;
    }

    /// <summary>True when exactly one non-empty header value equals one of the accepted keys.</summary>
    public static bool Matches(Microsoft.Extensions.Primitives.StringValues values, IReadOnlyList<byte[]> accepted)
    {
        ArgumentNullException.ThrowIfNull(accepted);
        if (values.Count != 1 || string.IsNullOrEmpty(values[0]))
        {
            return false;
        }

        var presented = Encoding.UTF8.GetBytes(values[0]!);
        var ok = false;
        foreach (var expected in accepted)
        {
            ok |= CryptographicOperations.FixedTimeEquals(presented, expected); // no early exit
        }

        return ok;
    }
}
