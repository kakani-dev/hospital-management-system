using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Hms.Modules.Identity.Email;
using Hms.Platform.Auth;
using Microsoft.Extensions.Options;

namespace Hms.Modules.Identity.Auth;

/// <summary>
/// Password-grant a new session after <c>identity.change_own_password</c> has committed. Waits
/// until the Unix second is strictly after the cutoff so the new access token is not rejected by
/// the fail-closed same-second rule (iat &lt;= floored cutoff). The password, tokens, and service
/// role key are never written to a log or an exception message.
/// </summary>
public sealed class GoTruePasswordSessionIssuer(
    HttpClient http,
    IOptions<SupabaseAuthOptions> options,
    TimeProvider clock) : IPasswordSessionIssuer
{
    public const string NotConfiguredMessage = "Password sign-in is not configured.";
    public const string IssueFailedMessage = "A new session could not be issued.";

    public async Task<IssuedSessionTokens> IssueAsync(
        Guid userId,
        string email,
        string password,
        long sessionsInvalidatedEpoch,
        Guid? tenantId,
        Guid? branchId,
        CancellationToken cancellationToken)
    {
        _ = userId;
        _ = tenantId;
        _ = branchId;
        var auth = options.Value;
        if (!GoTruePasswordlessSessionIssuer.IsAllowedProjectUrl(auth) || string.IsNullOrWhiteSpace(auth.ServiceRoleKey))
        {
            throw new InvalidOperationException(NotConfiguredMessage);
        }

        await WaitUntilAfterCutoffAsync(sessionsInvalidatedEpoch, clock, cancellationToken);

        var root = new Uri(auth.ProjectUrl.TrimEnd('/') + "/");
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(root, "auth/v1/token?grant_type=password"));
        request.Headers.TryAddWithoutValidation("apikey", auth.ServiceRoleKey);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", auth.ServiceRoleKey);
        request.Content = JsonContent.Create(new { email, password });
        using var response = await http.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(IssueFailedMessage);
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
        var access = GetString(doc.RootElement, "access_token");
        var refresh = GetString(doc.RootElement, "refresh_token");
        if (string.IsNullOrWhiteSpace(access) || string.IsNullOrWhiteSpace(refresh))
        {
            throw new InvalidOperationException(IssueFailedMessage);
        }

        var expiresIn = doc.RootElement.TryGetProperty("expires_in", out var exp) && exp.TryGetInt32(out var seconds)
            ? seconds
            : 3600;
        var tokenType = GetString(doc.RootElement, "token_type") ?? "bearer";
        return new IssuedSessionTokens(access, refresh, expiresIn, tokenType);
    }

    internal static async Task WaitUntilAfterCutoffAsync(long cutoffEpoch, TimeProvider clock, CancellationToken cancellationToken)
    {
        var deadline = clock.GetUtcNow().AddSeconds(2);
        while (clock.GetUtcNow().ToUnixTimeSeconds() <= cutoffEpoch)
        {
            if (clock.GetUtcNow() >= deadline)
            {
                throw new InvalidOperationException(IssueFailedMessage);
            }

            await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken);
        }
    }

    private static string? GetString(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}
