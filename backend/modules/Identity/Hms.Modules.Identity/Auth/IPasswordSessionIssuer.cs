namespace Hms.Modules.Identity.Auth;

/// <summary>A freshly issued access + refresh pair. Never logged or put in an exception message.</summary>
public sealed record IssuedSessionTokens(string AccessToken, string RefreshToken, int ExpiresIn, string TokenType)
{
    public override string ToString() => $"{nameof(IssuedSessionTokens)} {{ ExpiresIn = {ExpiresIn}, TokenType = {TokenType} }}";
}

/// <summary>
/// Issues a new GoTrue session after the caller has committed a password change. Production talks
/// to GoTrue; integration tests stub this so the in-process host does not need a live Auth server.
/// </summary>
public interface IPasswordSessionIssuer
{
    Task<IssuedSessionTokens> IssueAsync(
        Guid userId,
        string email,
        string password,
        long sessionsInvalidatedEpoch,
        Guid? tenantId,
        Guid? branchId,
        CancellationToken cancellationToken);
}
