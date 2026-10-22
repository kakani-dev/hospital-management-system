using MailKit.Net.Smtp;
using MailKit.Security;
using Microsoft.Extensions.Options;
using MimeKit;

namespace Hms.Modules.Identity.Email;

/// <summary>
/// Gmail SMTP on port 587 with STARTTLS. The password is taken from <see cref="SmtpOptions.Password"/>
/// at send time and is never written to a log, exception message or template.
/// </summary>
public sealed class SmtpEmailSender(IOptions<SmtpOptions> options) : IEmailSender
{
    public const string PasswordMissingMessage = "SMTP password is not configured. Set Smtp:Password from the environment (Smtp__Password).";

    public async Task SendAsync(OutgoingEmail email, CancellationToken cancellationToken)
    {
        var smtp = options.Value;
        if (string.IsNullOrWhiteSpace(smtp.Password))
        {
            throw new InvalidOperationException(PasswordMissingMessage);
        }

        if (!smtp.UseStartTls)
        {
            throw new InvalidOperationException("SMTP STARTTLS is required.");
        }

        if (string.IsNullOrWhiteSpace(smtp.Host) || string.IsNullOrWhiteSpace(smtp.Username) || string.IsNullOrWhiteSpace(smtp.FromAddress))
        {
            throw new InvalidOperationException("SMTP host, username and from address must be configured.");
        }

        var message = new MimeMessage();
        message.From.Add(new MailboxAddress(smtp.FromDisplayName, smtp.FromAddress));
        message.To.Add(MailboxAddress.Parse(email.To));
        message.Subject = email.Subject;
        var body = new BodyBuilder { TextBody = email.TextBody, HtmlBody = email.HtmlBody };
        message.Body = body.ToMessageBody();

        using var client = new SmtpClient { Timeout = 30_000 };
        await client.ConnectAsync(smtp.Host, smtp.Port, SecureSocketOptions.StartTls, cancellationToken);
        try
        {
            await client.AuthenticateAsync(smtp.Username, smtp.Password, cancellationToken);
            await client.SendAsync(message, cancellationToken);
        }
        finally
        {
            if (client.IsConnected)
            {
                await client.DisconnectAsync(true, cancellationToken);
            }
        }
    }
}
