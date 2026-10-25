using Hms.Modules.Billing.Payments;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Options;

namespace Hms.UnitTests;

public sealed class WebhookSignatureTests
{
    private const string Secret = "local-billing-webhook";
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
    private static readonly byte[] Body = "{\"eventId\":\"evt-1\",\"amountPaise\":50000}"u8.ToArray();

    [Fact]
    public void A_signature_from_the_current_secret_verifies()
    {
        var header = WebhookSignature.Sign(Secret, Body, Now.ToUnixTimeSeconds());
        Assert.True(WebhookSignature.Verify(Secret, null, Body, header, Now, TimeSpan.FromMinutes(5)));
    }

    [Fact]
    public void A_flipped_bit_is_rejected()
    {
        var header = WebhookSignature.Sign(Secret, Body, Now.ToUnixTimeSeconds());
        var flipped = header[..^1] + (header[^1] == 'a' ? "b" : "a");
        Assert.False(WebhookSignature.Verify(Secret, null, Body, flipped, Now, TimeSpan.FromMinutes(5)));
    }

    [Theory]
    [InlineData(-301)]
    [InlineData(301)]
    public void A_timestamp_outside_the_window_is_rejected(int skewSeconds)
    {
        var stamped = Now.AddSeconds(skewSeconds).ToUnixTimeSeconds();
        var header = WebhookSignature.Sign(Secret, Body, stamped);
        Assert.False(WebhookSignature.Verify(Secret, null, Body, header, Now, TimeSpan.FromMinutes(5)));
    }

    [Fact]
    public void A_short_hex_value_is_rejected()
    {
        var header = $"t={Now.ToUnixTimeSeconds()},v1=abcd";
        Assert.False(WebhookSignature.Verify(Secret, null, Body, header, Now, TimeSpan.FromMinutes(5)));
    }

    [Fact]
    public void An_empty_secret_never_verifies()
    {
        var header = WebhookSignature.Sign(Secret, Body, Now.ToUnixTimeSeconds());
        Assert.False(WebhookSignature.Verify("", null, Body, header, Now, TimeSpan.FromMinutes(5)));
    }

    [Fact]
    public void The_previous_secret_still_verifies_during_rotation()
    {
        var header = WebhookSignature.Sign("previous-local-secret", Body, Now.ToUnixTimeSeconds());
        Assert.True(WebhookSignature.Verify(Secret, "previous-local-secret", Body, header, Now, TimeSpan.FromMinutes(5)));
        Assert.False(WebhookSignature.Verify(Secret, null, Body, header, Now, TimeSpan.FromMinutes(5)));
    }

    [Fact]
    public void The_sandbox_adapter_serves_only_stub_and_sandbox_and_uses_the_sandbox_vpa()
    {
        var provider = new StubPaymentProvider(Options.Create(new BillingPaymentOptions
        {
            WebhookSecret = Secret,
            SandboxPayeeAddress = "sandbox@medicore",
        }));
        var uri = provider.UpiUri(50000, "order-1");
        Assert.Contains("upi://pay", uri, StringComparison.Ordinal);
        Assert.Contains("sandbox%40medicore", uri, StringComparison.Ordinal);
        Assert.DoesNotContain(Secret, uri, StringComparison.Ordinal);
        Assert.True(provider.Serves("stub"));
        Assert.True(provider.Serves("SANDBOX"));
        Assert.False(provider.Serves("razorpay"));

        var header = WebhookSignature.Sign(Secret, Body, Now.ToUnixTimeSeconds());
        Assert.True(provider.VerifyWebhook("stub", Body, header, Now));
        Assert.False(provider.VerifyWebhook("razorpay", Body, header, Now));
    }

    [Fact]
    public void A_payee_with_whitespace_falls_back_to_the_sandbox_address()
    {
        var provider = new StubPaymentProvider(Options.Create(new BillingPaymentOptions
        {
            SandboxPayeeAddress = "not a vpa",
        }));
        Assert.Contains("sandbox%40medicore", provider.UpiUri(100, "order-2"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task The_email_dispatcher_check_stays_healthy_until_three_failures()
    {
        var health = new Hms.Modules.Identity.Email.EmailDispatcherHealth(Options.Create(new Hms.Modules.Identity.Email.EmailDeliveryOptions
        {
            Dispatcher = new Hms.Modules.Identity.Email.EmailDispatcherOptions { Enabled = true },
        }));
        var check = new Hms.Modules.Identity.Email.EmailDispatcherHealthCheck(health);
        Assert.Equal(HealthStatus.Healthy, (await check.CheckHealthAsync(new HealthCheckContext())).Status);
        health.RecordFailure(Now);
        health.RecordFailure(Now);
        health.RecordFailure(Now);
        Assert.Equal(HealthStatus.Degraded, (await check.CheckHealthAsync(new HealthCheckContext())).Status);
    }
}
