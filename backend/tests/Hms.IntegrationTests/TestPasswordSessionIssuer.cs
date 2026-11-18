using Hms.Modules.Identity.Auth;

namespace Hms.IntegrationTests;

/// <summary>
/// In-process stand-in for GoTrue. Issues a test JWT with iat strictly after the cutoff so the
/// completing session can keep calling the API. The password is ignored and never logged.
/// </summary>
internal sealed class TestPasswordSessionIssuer : IPasswordSessionIssuer
{
    public Task<IssuedSessionTokens> IssueAsync(
        Guid userId,
        string email,
        string password,
        long sessionsInvalidatedEpoch,
        Guid? tenantId,
        Guid? branchId,
        CancellationToken cancellationToken)
    {
        _ = password;
        var claims = new Dictionary<string, object> { ["email"] = email };
        if (tenantId is { } tenant)
        {
            claims["tenant_id"] = tenant.ToString();
        }

        if (branchId is { } branch)
        {
            claims["branch_id"] = branch.ToString();
        }

        var issuedAt = DateTimeOffset.FromUnixTimeSeconds(sessionsInvalidatedEpoch + 1).UtcDateTime;
        var access = TestJwt.Create(userId, claims, issuedAt: issuedAt);
        return Task.FromResult(new IssuedSessionTokens(access, $"test-refresh-{userId:N}", 3600, "bearer"));
    }
}
