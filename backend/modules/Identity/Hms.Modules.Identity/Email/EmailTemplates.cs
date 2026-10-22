using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Hms.Modules.Identity.Email;

/// <summary>
/// Plain branded HTML and text for product mail. Every link is built from the configured
/// public base URL; the production host is not embedded here.
/// </summary>
public static partial class EmailTemplates
{
    public static RenderedEmail Render(string templateKey, JsonElement variables, string publicBaseUrl)
    {
        var hospital = Optional(variables, "hospitalName");
        var contact = Optional(variables, "contactName");
        return templateKey switch
        {
            "invite_link" => Invite(hospital, Optional(variables, "branchName"), Require(variables, "role"), Link(variables, publicBaseUrl), Require(variables, "expiresOn")),
            "signup_received" => Received(hospital, contact),
            "signup_approved" => Approved(hospital, contact, Link(variables, publicBaseUrl), Require(variables, "expiresOn")),
            "signup_rejected" => Rejected(hospital, contact, Require(variables, "reason")),
            "sign_in_code" => SignInCode(hospital, Require(variables, "code"), Link(variables, publicBaseUrl), Require(variables, "expiresOn")),
            _ => throw new InvalidOperationException("Unknown email template."),
        };
    }

    private static RenderedEmail Invite(string? hospital, string? branch, string role, string link, string expiresOn)
    {
        var where = string.IsNullOrWhiteSpace(hospital) ? "a hospital" : hospital;
        var scope = string.IsNullOrWhiteSpace(branch) ? "all branches" : branch;
        var roleLabel = RoleLabel(role);
        var when = FormatWhen(expiresOn);
        var subject = $"You're invited to {where} on MediCore HMS";
        var text =
            $"You have been invited to {where} on MediCore HMS as {roleLabel} ({scope}).\n\n" +
            $"Open this link. It works once and expires {when}. On that page we email a one-time sign-in code to this address. " +
            "You then choose your own password. Nobody sends you a password.\n\n" +
            $"{link}\n\n" +
            "If you were not expecting this invitation, you can ignore this email.\n";
        var html = Document(subject, $"""
            <p>You have been invited to <strong>{H(where)}</strong> on MediCore HMS as {H(roleLabel)} ({H(scope)}).</p>
            <p>The link works once and expires {H(when)}. On that page we email a one-time sign-in code to this address.
            You then choose your own password. Nobody sends you a password.</p>
            {Button("Open invitation", link)}
            """);
        return new RenderedEmail(subject, text, html);
    }

    private static RenderedEmail Received(string? hospital, string? contact)
    {
        var name = string.IsNullOrWhiteSpace(contact) ? "there" : contact;
        var where = string.IsNullOrWhiteSpace(hospital) ? "your hospital" : hospital;
        const string subject = "We received your MediCore HMS registration";
        var text =
            $"Hello {name},\n\n" +
            $"We received the registration for {where}. A platform administrator will review it. " +
            "This mailbox is notified when the request is approved or declined. Nothing is created until then.\n\n" +
            "If you did not submit this request, you can ignore this email.\n";
        var html = Document(subject, $"""
            <p>Hello {H(name)},</p>
            <p>We received the registration for <strong>{H(where)}</strong>. A platform administrator will review it.
            This mailbox is notified when the request is approved or declined. Nothing is created until then.</p>
            <p>If you did not submit this request, you can ignore this email.</p>
            """);
        return new RenderedEmail(subject, text, html);
    }

    private static RenderedEmail Approved(string? hospital, string? contact, string link, string expiresOn)
    {
        var name = string.IsNullOrWhiteSpace(contact) ? "there" : contact;
        var where = string.IsNullOrWhiteSpace(hospital) ? "Your hospital" : hospital;
        var when = FormatWhen(expiresOn);
        var subject = $"{where} is approved on MediCore HMS";
        var text =
            $"Hello {name},\n\n" +
            $"{where} has been approved. You are the first administrator.\n\n" +
            $"Open the link below. It works once and expires {when}. On that page we email a one-time sign-in code to this address. " +
            "You then choose your own password. Nobody sends you a password.\n\n" +
            $"{link}\n";
        var html = Document(subject, $"""
            <p>Hello {H(name)},</p>
            <p><strong>{H(where)}</strong> has been approved. You are the first administrator.</p>
            <p>The link works once and expires {H(when)}. On that page we email a one-time sign-in code to this address.
            You then choose your own password. Nobody sends you a password.</p>
            {Button("Open your invite", link)}
            """);
        return new RenderedEmail(subject, text, html);
    }

    private static RenderedEmail Rejected(string? hospital, string? contact, string reason)
    {
        var name = string.IsNullOrWhiteSpace(contact) ? "there" : contact;
        var where = string.IsNullOrWhiteSpace(hospital) ? "Your hospital" : hospital;
        const string subject = "Your MediCore HMS registration was not approved";
        var text =
            $"Hello {name},\n\n" +
            $"The registration for {where} was not approved.\n\n" +
            $"Reason: {reason}\n\n" +
            "You can submit a new request if the details change.\n";
        var html = Document(subject, $"""
            <p>Hello {H(name)},</p>
            <p>The registration for <strong>{H(where)}</strong> was not approved.</p>
            <p><strong>Reason:</strong> {H(reason)}</p>
            <p>You can submit a new request if the details change.</p>
            """);
        return new RenderedEmail(subject, text, html);
    }

    private static RenderedEmail SignInCode(string? hospital, string code, string link, string expiresOn)
    {
        if (!SixDigits().IsMatch(code))
        {
            throw new InvalidOperationException("Sign-in email is missing a code.");
        }

        var where = string.IsNullOrWhiteSpace(hospital) ? "your hospital" : hospital;
        var when = FormatWhen(expiresOn);
        var magic = $"{link}#code={code}";
        const string subject = "Your MediCore HMS sign-in code";
        var text =
            $"Your sign-in code for {where} is {code}.\n\n" +
            $"It expires {when}. Open the link below, or type the code on the invite page. " +
            "Then choose your own password. We never email a password.\n\n" +
            $"{magic}\n";
        var html = Document(subject, $"""
            <p>Your sign-in code for <strong>{H(where)}</strong> is</p>
            <p style="font-size:28px;letter-spacing:4px;font-weight:bold;">{H(code)}</p>
            <p>It expires {H(when)}. Then choose your own password. We never email a password.</p>
            {Button("Sign in with this code", magic)}
            """);
        return new RenderedEmail(subject, text, html);
    }

    private static string Link(JsonElement variables, string publicBaseUrl)
    {
        if (!Uri.TryCreate(publicBaseUrl?.Trim(), UriKind.Absolute, out var uri)
            || uri.UserInfo.Length > 0
            || (uri.Scheme != Uri.UriSchemeHttps && uri.Scheme != Uri.UriSchemeHttp))
        {
            throw new InvalidOperationException("Email:PublicBaseUrl must be an absolute http(s) URL without credentials.");
        }

        var token = Require(variables, "token");
        if (!Token().IsMatch(token))
        {
            throw new InvalidOperationException("Invite email is missing a token.");
        }

        return $"{uri.GetLeftPart(UriPartial.Authority).TrimEnd('/')}{uri.AbsolutePath.TrimEnd('/')}/invite/{token}";
    }

    private static string Document(string title, string body) =>
        $"""
        <!DOCTYPE html>
        <html lang="en">
        <body style="margin:0;background:#f4f7f6;color:#1c2b2a;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f7f6;">
            <tr><td align="center" style="padding:24px 12px;">
              <table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#ffffff;border:1px solid #d5e0dc;border-radius:8px;">
                <tr><td style="background:#0f3d3a;color:#ffffff;padding:16px 24px;font-family:Arial,sans-serif;font-size:18px;">{H(title)}</td></tr>
                <tr><td style="padding:24px;font-family:Arial,sans-serif;font-size:15px;line-height:1.5;">{body}</td></tr>
              </table>
              <p style="font-family:Arial,sans-serif;font-size:12px;color:#5c6b69;">Sent by MediCore HMS.</p>
            </td></tr>
          </table>
        </body>
        </html>
        """;

    private static string Button(string label, string link) =>
        $"""
        <p><a href="{H(link)}" style="display:inline-block;background:#0f3d3a;color:#ffffff;text-decoration:none;padding:10px 16px;border-radius:4px;">{H(label)}</a></p>
        <p style="color:#5c6b69;font-size:13px;">If the button does not work, copy this link:<br>{H(link)}</p>
        """;

    private static string RoleLabel(string role) => role switch
    {
        "tenant_admin" => "hospital administrator",
        "lab_technician" => "lab technician",
        _ => role.Replace('_', ' '),
    };

    private static string FormatWhen(string expiresOn)
    {
        if (DateTimeOffset.TryParse(expiresOn, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var when))
        {
            return when.UtcDateTime.ToString("dd MMM yyyy HH:mm 'UTC'", CultureInfo.InvariantCulture);
        }

        return expiresOn;
    }

    private static string Require(JsonElement variables, string name)
    {
        var value = Optional(variables, name);
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException($"Email template is missing {name}.");
        }

        return value;
    }

    private static string? Optional(JsonElement variables, string name)
    {
        if (variables.ValueKind != JsonValueKind.Object || !variables.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        return value.GetString();
    }

    private static string H(string value) => WebUtility.HtmlEncode(value);

    [GeneratedRegex("^[0-9a-fA-F]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex Token();

    [GeneratedRegex("^[0-9]{6}$", RegexOptions.CultureInvariant)]
    private static partial Regex SixDigits();
}
