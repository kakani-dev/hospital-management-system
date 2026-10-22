using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Hms.Platform.Auth;
using Microsoft.Extensions.Options;

namespace Hms.Modules.Identity.Email;

/// <summary>
/// Turns a verified invite email into a GoTrue magic-link token hash. GoTrue does not send mail;
/// the code itself was already queued on the identity outbox. The service-role key is read from
/// configuration and is never written to a log or an exception message.
/// </summary>
public sealed class GoTruePasswordlessSessionIssuer(HttpClient http, IOptions<SupabaseAuthOptions> options) : IPasswordlessSessionIssuer
{
    public const string NotConfiguredMessage = "Passwordless sign-in is not configured.";

    public bool IsConfigured
    {
        get
        {
            var auth = options.Value;
            return IsAllowedProjectUrl(auth) && !string.IsNullOrWhiteSpace(auth.ServiceRoleKey);
        }
    }

    public async Task<PasswordlessProof> CreateAsync(string email, CancellationToken cancellationToken)
    {
        var auth = options.Value;
        if (!IsConfigured)
        {
            throw new InvalidOperationException(NotConfiguredMessage);
        }

        var root = new Uri(auth.ProjectUrl.TrimEnd('/') + "/");
        using var create = Authorized(HttpMethod.Post, new Uri(root, "auth/v1/admin/users"), auth.ServiceRoleKey);
        create.Content = JsonContent.Create(new { email, email_confirm = true, user_metadata = new { needs_password = true } });
        using (var created = await http.SendAsync(create, cancellationToken))
        {
            if (!created.IsSuccessStatusCode && !IsAlreadyRegistered(created.StatusCode))
            {
                throw new InvalidOperationException("Passwordless sign-in could not be started.");
            }
        }

        using var link = Authorized(HttpMethod.Post, new Uri(root, "auth/v1/admin/generate_link"), auth.ServiceRoleKey);
        link.Content = JsonContent.Create(new { type = "magiclink", email });
        using var response = await http.SendAsync(link, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException("Passwordless sign-in could not be started.");
        }

        var hash = await ReadTokenHashAsync(response, cancellationToken);
        if (string.IsNullOrWhiteSpace(hash))
        {
            throw new InvalidOperationException("Passwordless sign-in could not be started.");
        }

        return new PasswordlessProof(hash, "magiclink");
    }

    internal static bool IsAllowedProjectUrl(SupabaseAuthOptions auth)
    {
        if (!Uri.TryCreate(auth.ProjectUrl?.Trim(), UriKind.Absolute, out var uri) || uri.UserInfo.Length > 0)
        {
            return false;
        }

        if (uri.Scheme == Uri.UriSchemeHttps)
        {
            return true;
        }

        return auth.AllowInsecureHttp && uri.Scheme == Uri.UriSchemeHttp;
    }

    private static bool IsAlreadyRegistered(System.Net.HttpStatusCode status) =>
        status is System.Net.HttpStatusCode.Conflict or System.Net.HttpStatusCode.UnprocessableEntity;

    private static HttpRequestMessage Authorized(HttpMethod method, Uri uri, string serviceRoleKey)
    {
        var request = new HttpRequestMessage(method, uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", serviceRoleKey);
        request.Headers.TryAddWithoutValidation("apikey", serviceRoleKey);
        return request;
    }

    private static async Task<string?> ReadTokenHashAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
        var root = document.RootElement;
        if (TryHash(root, out var hash))
        {
            return hash;
        }

        return root.TryGetProperty("properties", out var properties) && TryHash(properties, out hash) ? hash : null;
    }

    private static bool TryHash(JsonElement element, out string? hash)
    {
        hash = null;
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty("hashed_token", out var value) || value.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        hash = value.GetString();
        return !string.IsNullOrWhiteSpace(hash);
    }
}

public interface IPasswordlessSessionIssuer
{
    bool IsConfigured { get; }

    Task<PasswordlessProof> CreateAsync(string email, CancellationToken cancellationToken);
}

/// <summary>Material the browser passes to <c>supabase.auth.verifyOtp</c>. Not an application password.</summary>
public sealed record PasswordlessProof(string TokenHash, string VerificationType);
