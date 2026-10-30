using System.Text.RegularExpressions;

namespace Hms.Edge;

/// <summary>
/// Allowed browser origins: exact <c>Cors:AllowedOrigins</c> (the deployed web origin and
/// local dev, set per environment) plus anchored regexes in <c>Cors:AllowedOriginPatterns</c> for this project's Vercel preview
/// URLs only (never a bare <c>*.vercel.app</c>, which any Vercel user could register).
/// </summary>
public static class EdgeCors
{
    public static Func<string, bool> Allowed(IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var exact = new HashSet<string>(
            (configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? []).Select(o => o.TrimEnd('/')),
            StringComparer.OrdinalIgnoreCase);
        var patterns = (configuration.GetSection("Cors:AllowedOriginPatterns").Get<string[]>() ?? [])
            .Where(p => !string.IsNullOrWhiteSpace(p))
            .Select(p => new Regex(Anchor(p), RegexOptions.CultureInvariant | RegexOptions.IgnoreCase, TimeSpan.FromMilliseconds(50)))
            .ToList();
        return origin => exact.Contains(origin) || patterns.Exists(r => r.IsMatch(origin));
    }

    private static string Anchor(string pattern) =>
        (pattern.StartsWith('^') ? pattern : "^" + pattern) is var p && p.EndsWith('$') ? p : p + "$";
}
