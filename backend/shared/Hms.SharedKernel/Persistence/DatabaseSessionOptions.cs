using System.Text.RegularExpressions;

namespace Hms.SharedKernel.Persistence;

/// <summary>
/// The PostgreSQL role an authenticated request assumes (<c>Database:SessionRole</c>).
/// Each service sets its own group role (<c>hms_svc_*</c>), which holds grants only on that
/// service's schema plus approved <c>_v1</c> functions. The legacy host leaves this unset and
/// keeps <c>authenticated</c>. The JWT claim <c>role</c> stays <c>authenticated</c> either way
/// (<see cref="DbSessionContext"/>); only the session role changes.
/// </summary>
public sealed partial class DatabaseSessionOptions
{
    public const string ConfigKey = "Database:SessionRole";
    public const string DefaultRole = "authenticated";

    public string AuthenticatedRole { get; }

    public DatabaseSessionOptions(string? authenticatedRole = null)
    {
        AuthenticatedRole = string.IsNullOrWhiteSpace(authenticatedRole) ? DefaultRole : authenticatedRole.Trim();
        if (!RolePattern().IsMatch(AuthenticatedRole))
        {
            throw new ArgumentException(
                $"Database session role '{AuthenticatedRole}' must be a PostgreSQL identifier.",
                nameof(authenticatedRole));
        }
    }

    [GeneratedRegex("^[a-z_][a-z0-9_]{0,62}$", RegexOptions.CultureInvariant)]
    private static partial Regex RolePattern();
}
