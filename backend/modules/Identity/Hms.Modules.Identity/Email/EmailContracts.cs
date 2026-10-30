using System.Text.Json;

namespace Hms.Modules.Identity.Email;

/// <summary>
/// Sends one already-rendered message. Gmail SMTP is the current implementation;
/// a Resend or SES sender can replace it without changing templates or the outbox.
/// </summary>
public interface IEmailSender
{
    Task SendAsync(OutgoingEmail email, CancellationToken cancellationToken);
}

/// <summary>Consumer side of identity email events on <c>messaging.outbox</c>.</summary>
public interface IEmailOutbox
{
    Task<int> SendsTodayAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<EmailOutboxMessage>> ClaimAsync(string workerId, int batchSize, TimeSpan lease, CancellationToken cancellationToken);

    Task<bool> AlreadySentAsync(Guid eventId, CancellationToken cancellationToken);

    Task<PendingEmail?> LoadAsync(Guid pendingEmailId, CancellationToken cancellationToken);

    /// <returns><see langword="true"/> when this call recorded the event (the first sender).</returns>
    Task<bool> RecordSentAsync(Guid eventId, Guid tenantId, CancellationToken cancellationToken);

    Task RedactAsync(Guid pendingEmailId, CancellationToken cancellationToken);

    Task CompleteAsync(long id, string workerId, CancellationToken cancellationToken);

    Task FailAsync(long id, string workerId, string failure, TimeSpan retryIn, CancellationToken cancellationToken);
}

/// <summary>A claimed <c>email_message</c> row. The payload has no recipient, name, token or reason.</summary>
public sealed record EmailOutboxMessage(long Id, Guid EventId, Guid TenantId, Guid PendingEmailId, string TemplateKey, int Attempts);

/// <summary>Sensitive send material loaded from <c>identity.pending_emails</c> at delivery time.</summary>
public sealed record PendingEmail(string TemplateKey, string Recipient, JsonElement Variables);

public sealed record OutgoingEmail(string To, string Subject, string TextBody, string HtmlBody);

public sealed record RenderedEmail(string Subject, string TextBody, string HtmlBody);

/// <summary>Gmail SMTP. The password is read from configuration (<c>Smtp:Password</c> / <c>Smtp__Password</c>) and is never logged.</summary>
public sealed class SmtpOptions
{
    public const string Section = "Smtp";

    /// <summary>Connect/send timeout in seconds (Smtp:TimeoutSeconds, 1-300).</summary>
    public int TimeoutSeconds { get; set; } = 30;

    public string Host { get; set; } = "smtp.gmail.com";

    public int Port { get; set; } = 587;

    public bool UseStartTls { get; set; } = true;

    public string Username { get; set; } = "";

    public string Password { get; set; } = "";

    public string FromAddress { get; set; } = "";

    public string FromDisplayName { get; set; } = "MediCore HMS";
}

public sealed class EmailDispatcherOptions
{
    /// <summary>Off until the identity container is given <c>Smtp__Password</c>. Only the identity service turns this on.</summary>
    public bool Enabled { get; set; }

    public int BatchSize { get; set; } = 20;

    public int PollIntervalSeconds { get; set; } = 5;

    public int LeaseSeconds { get; set; } = 60;

    public int RetryBaseSeconds { get; set; } = 30;

    /// <summary>
    /// App-mail cap per UTC day. A Gmail consumer account allows about 500 messages a day for the
    /// whole mailbox, and Supabase Auth shares that quota when custom SMTP points at the same account.
    /// </summary>
    public int DailySendLimit { get; set; } = 400;
}

/// <summary>Product mail settings. <see cref="PublicBaseUrl"/> is the web app origin used in links.</summary>
public sealed class EmailDeliveryOptions
{
    public const string Section = "Email";

    public string PublicBaseUrl { get; set; } = "";

    public EmailDispatcherOptions Dispatcher { get; set; } = new();
}
