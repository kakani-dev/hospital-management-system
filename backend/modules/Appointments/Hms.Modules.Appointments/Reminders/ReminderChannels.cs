using System.Net.Http.Json;
using MailKit.Net.Smtp;
using MailKit.Security;
using Microsoft.Extensions.Options;
using MimeKit;

namespace Hms.Modules.Appointments.Reminders;

public interface IReminderChannel
{
    string Channel { get; }
    bool IsConfigured { get; }
    Task SendAsync(string recipient, string subject, string body, CancellationToken ct);
}

/// <summary>MailKit over SMTP + STARTTLS (free Gmail SMTP). The password is never logged.</summary>
public sealed class EmailReminderChannel(IOptions<ReminderSmtpOptions> smtpOptions) : IReminderChannel
{
    public string Channel => "email";
    public bool IsConfigured => smtpOptions.Value.IsConfigured;

    public async Task SendAsync(string recipient, string subject, string body, CancellationToken ct)
    {
        var smtp = smtpOptions.Value;
        if (!smtp.IsConfigured)
        {
            throw new InvalidOperationException("Email is not configured.");
        }

        var message = new MimeMessage();
        message.From.Add(new MailboxAddress(smtp.FromDisplayName, smtp.FromAddress!));
        message.To.Add(MailboxAddress.Parse(recipient));
        message.Subject = subject;
        message.Body = new TextPart("plain") { Text = body };

        using var client = new SmtpClient { Timeout = (int)TimeSpan.FromSeconds(Math.Clamp(smtp.TimeoutSeconds, 1, 300)).TotalMilliseconds };
        await client.ConnectAsync(smtp.Host!, smtp.Port, SecureSocketOptions.StartTls, ct);
        try
        {
            await client.AuthenticateAsync(smtp.Username!, smtp.Password!, ct);
            await client.SendAsync(message, ct);
        }
        finally
        {
            if (client.IsConnected)
            {
                await client.DisconnectAsync(true, ct);
            }
        }
    }
}

/// <summary>Optional self-hosted WAHA: POST {BaseUrl}/api/sendText. Off unless Reminders:WhatsApp:BaseUrl is set.</summary>
public sealed class WahaReminderChannel(HttpClient http, IOptions<ReminderOptions> options) : IReminderChannel
{
    public string Channel => "whatsapp";
    public bool IsConfigured => options.Value.WhatsApp.IsConfigured;

    public async Task SendAsync(string recipient, string subject, string body, CancellationToken ct)
    {
        var waha = options.Value.WhatsApp;
        if (!waha.IsConfigured)
        {
            throw new InvalidOperationException("WhatsApp is not configured.");
        }

        var digits = ReminderText.Normalize(recipient);
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(new Uri(waha.BaseUrl!), "/api/sendText"))
        {
            Content = JsonContent.Create(new { session = waha.Session, chatId = $"{digits}@c.us", text = body }),
        };
        if (!string.IsNullOrWhiteSpace(waha.ApiKey))
        {
            request.Headers.Add("X-Api-Key", waha.ApiKey);
        }

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(waha.TimeoutSeconds, 1, 120)));
        using var response = await http.SendAsync(request, cts.Token);
        if (!response.IsSuccessStatusCode)
        {
            throw new HttpRequestException($"WhatsApp gateway returned {(int)response.StatusCode}.");
        }
    }
}
