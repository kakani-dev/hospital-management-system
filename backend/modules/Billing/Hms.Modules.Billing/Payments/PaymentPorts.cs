using System.Globalization;
using Microsoft.Extensions.Options;

namespace Hms.Modules.Billing.Payments;

public sealed record ShareResult(string Channel, string Status);

/// <summary>
/// Collect adapter. v1 registers only the sandbox stub: a UPI intent and HMAC
/// verification with the local webhook secret. No bank, MID, or live provider key.
/// </summary>
public interface IPaymentProvider
{
    string Name { get; }

    bool Serves(string providerName);

    /// <summary>UPI intent. <paramref name="payeeAddress"/> is the branch VPA; null falls back to the configured sandbox payee.</summary>
    string UpiUri(long amountPaise, string orderId, string? payeeAddress = null, string? payeeName = null);

    bool VerifyWebhook(string providerName, ReadOnlySpan<byte> body, string? signatureHeader, DateTimeOffset now);
}

/// <summary>Sandbox UPI and webhook settings. Secrets come from the environment, not the database.</summary>
public sealed class BillingPaymentOptions
{
    public const string Section = "Billing";

    public string WebhookSecret { get; set; } = "";

    /// <summary>Optional previous secret, checked as well so a rotation overlap still verifies.</summary>
    public string WebhookSecretPrevious { get; set; } = "";

    public int WebhookToleranceSeconds { get; set; } = 300;

    public string SandboxPayeeAddress { get; set; } = "sandbox@medicore";

    public string SandboxPayeeName { get; set; } = "MediCore Sandbox";
}

/// <summary>WhatsApp / SMS send. v1 records the intent and does not deliver.</summary>
public interface IBillShareSender
{
    Task<ShareResult> SendAsync(string channel, string destination, string linkPath, CancellationToken ct);
}

/// <summary>Sandbox adapter. Accepts the provider names <c>stub</c> and <c>sandbox</c> only.</summary>
public sealed class StubPaymentProvider(IOptions<BillingPaymentOptions> options) : IPaymentProvider
{
    public string Name => "stub";

    public bool Serves(string providerName) =>
        providerName.Equals("stub", StringComparison.OrdinalIgnoreCase)
        || providerName.Equals("sandbox", StringComparison.OrdinalIgnoreCase);

    public string UpiUri(long amountPaise, string orderId, string? payeeAddress = null, string? payeeName = null)
    {
        var rupees = (amountPaise / 100m).ToString("0.00", CultureInfo.InvariantCulture);
        var usesBranch = !string.IsNullOrWhiteSpace(payeeAddress) && !payeeAddress.Any(char.IsWhiteSpace);
        var payee = usesBranch ? payeeAddress!.Trim() : Payee();
        var name = usesBranch && !string.IsNullOrWhiteSpace(payeeName) ? payeeName.Trim()
            : string.IsNullOrWhiteSpace(options.Value.SandboxPayeeName) ? "MediCore Sandbox" : options.Value.SandboxPayeeName.Trim();
        return string.Create(
            CultureInfo.InvariantCulture,
            $"upi://pay?pa={Uri.EscapeDataString(payee)}&pn={Uri.EscapeDataString(name)}&am={rupees}&tr={Uri.EscapeDataString(orderId)}&cu=INR");
    }

    public bool VerifyWebhook(string providerName, ReadOnlySpan<byte> body, string? signatureHeader, DateTimeOffset now)
    {
        if (!Serves(providerName))
        {
            return false;
        }

        var configured = options.Value;
        var tolerance = TimeSpan.FromSeconds(Math.Clamp(configured.WebhookToleranceSeconds, 1, 3600));
        return WebhookSignature.Verify(
            configured.WebhookSecret,
            configured.WebhookSecretPrevious,
            body,
            signatureHeader,
            now,
            tolerance);
    }

    private string Payee()
    {
        var payee = options.Value.SandboxPayeeAddress;
        if (string.IsNullOrWhiteSpace(payee) || payee.Any(char.IsWhiteSpace))
        {
            return "sandbox@medicore";
        }

        return payee.Trim();
    }
}

public sealed class StubBillShareSender : IBillShareSender
{
    public Task<ShareResult> SendAsync(string channel, string destination, string linkPath, CancellationToken ct) =>
        Task.FromResult(new ShareResult(channel, "queued"));
}
