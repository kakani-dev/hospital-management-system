using System.Globalization;

namespace Hms.Modules.Billing.Payments;

public sealed record ShareResult(string Channel, string Status);

/// <summary>Provider-agnostic collect. v1 ships a stub that prints a UPI intent and does not call a bank.</summary>
public interface IPaymentProvider
{
    string Name { get; }

    string UpiUri(long amountPaise, string orderId);
}

/// <summary>WhatsApp / SMS send. v1 records the intent and does not deliver.</summary>
public interface IBillShareSender
{
    Task<ShareResult> SendAsync(string channel, string destination, string linkPath, CancellationToken ct);
}

public sealed class StubPaymentProvider : IPaymentProvider
{
    public string Name => "stub";

    public string UpiUri(long amountPaise, string orderId)
    {
        var rupees = (amountPaise / 100m).ToString("0.00", CultureInfo.InvariantCulture);
        return $"upi://pay?pa=stub@medicore&pn=MediCore&am={rupees}&tr={Uri.EscapeDataString(orderId)}&cu=INR";
    }
}

public sealed class StubBillShareSender : IBillShareSender
{
    public Task<ShareResult> SendAsync(string channel, string destination, string linkPath, CancellationToken ct) =>
        Task.FromResult(new ShareResult(channel, "queued"));
}
