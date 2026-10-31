namespace Hms.Modules.Appointments.Reminders;

/// <summary>How far reminder delivery may go. There is deliberately NO "live" mode in code (#59).</summary>
public enum ReminderDeliveryMode
{
    /// <summary>Nothing is claimed or sent (default; fail closed).</summary>
    Off,

    /// <summary>Only addresses / numbers on <see cref="ReminderOptions.TestRecipients"/> receive anything; every other row is marked skipped.</summary>
    TestRecipientsOnly,
}

/// <summary><c>Reminders:</c> configuration for the scheduling service. Secrets come from the environment only.</summary>
public sealed class ReminderOptions
{
    public const string Section = "Reminders";

    /// <summary>Raw mode string; anything other than <c>TestRecipientsOnly</c> means Off.</summary>
    public string Mode { get; set; } = nameof(ReminderDeliveryMode.Off);

    /// <summary>Allowlist of synthetic test emails / E.164 numbers. Empty = nothing is ever sent.</summary>
    public List<string> TestRecipients { get; set; } = [];

    /// <summary>Hangfire cron for the sweep (UTC).</summary>
    public string SweepCron { get; set; } = "*/5 * * * *";

    public int BatchSize { get; set; } = 50;

    public string EmailSubject { get; set; } = "Appointment reminder";

    public WahaOptions WhatsApp { get; set; } = new();

    public ReminderDeliveryMode DeliveryMode =>
        string.Equals(Mode?.Trim(), nameof(ReminderDeliveryMode.TestRecipientsOnly), StringComparison.OrdinalIgnoreCase)
            ? ReminderDeliveryMode.TestRecipientsOnly
            : ReminderDeliveryMode.Off;
}

/// <summary>Optional self-hosted WAHA (WhatsApp HTTP API). Unset BaseUrl = WhatsApp channel unavailable.</summary>
public sealed class WahaOptions
{
    public string? BaseUrl { get; set; }
    public string Session { get; set; } = "default";
    public string? ApiKey { get; set; }
    public int TimeoutSeconds { get; set; } = 15;

    public bool IsConfigured => Uri.TryCreate(BaseUrl, UriKind.Absolute, out _);
}

/// <summary><c>Smtp:</c> (same keys as the identity service; the password is only ever read from <c>Smtp__Password</c>).</summary>
public sealed class ReminderSmtpOptions
{
    public const string Section = "Smtp";
    public string? Host { get; set; }
    public int Port { get; set; } = 587;
    public string? Username { get; set; }
    public string? Password { get; set; }
    public string? FromAddress { get; set; }
    public string FromDisplayName { get; set; } = "Appointments";
    public bool UseStartTls { get; set; } = true;
    public int TimeoutSeconds { get; set; } = 30;

    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(Host) && !string.IsNullOrWhiteSpace(Username)
        && !string.IsNullOrWhiteSpace(Password) && !string.IsNullOrWhiteSpace(FromAddress) && UseStartTls;
}
