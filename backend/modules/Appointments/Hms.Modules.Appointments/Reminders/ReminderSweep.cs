using Hangfire;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Hms.Modules.Appointments.Reminders;

/// <summary>
/// The Hangfire recurring job. Claims due reminders (the DB decides who is due: settings, lead time,
/// quiet hours, walk-ins, opt-outs, cancellations, reschedules) and delivers them ONLY to configured
/// test recipients. Anyone else is marked skipped. Safe with several replicas (SKIP LOCKED leases).
/// </summary>
public sealed partial class ReminderSweep(
    IReminderStore store, IEnumerable<IReminderChannel> channels, IOptions<ReminderOptions> options, ILogger<ReminderSweep> logger)
{
    public const string JobId = "appointment-reminders";
    public const string NotTestRecipient = "not a test recipient (reminders are in test mode)";

    [DisableConcurrentExecution(300)]
    [AutomaticRetry(Attempts = 0)]
    public async Task<int> RunAsync(CancellationToken ct)
    {
        var settings = options.Value;
        if (settings.DeliveryMode == ReminderDeliveryMode.Off)
        {
            return 0;
        }

        var due = await store.ClaimAsync(settings.BatchSize, ct);
        var sent = 0;
        foreach (var reminder in due)
        {
            var masked = ReminderText.Mask(reminder.Recipient);
            var channel = channels.FirstOrDefault(c => c.Channel == reminder.Channel);
            if (string.IsNullOrWhiteSpace(reminder.Recipient))
            {
                await store.CompleteAsync(reminder.ReminderId, "skipped", "contact removed before sending", masked, ct);
                continue;
            }

            if (!ReminderText.IsTestRecipient(reminder.Recipient, settings.TestRecipients))
            {
                await store.CompleteAsync(reminder.ReminderId, "skipped", NotTestRecipient, masked, ct);
                continue;
            }

            if (channel is null || !channel.IsConfigured)
            {
                await store.CompleteAsync(reminder.ReminderId, "skipped", $"{reminder.Channel} is not configured", masked, ct);
                continue;
            }

            try
            {
                await channel.SendAsync(reminder.Recipient, settings.EmailSubject, ReminderText.Body(reminder), ct);
                await store.CompleteAsync(reminder.ReminderId, "sent", "delivered to test recipient", masked, ct);
                sent++;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // Type only: provider messages can echo addresses or credentials.
                LogSendFailed(logger, reminder.ReminderId, reminder.Channel, ex.GetType().Name);
                await store.CompleteAsync(reminder.ReminderId, "failed", $"send failed ({ex.GetType().Name}); will retry", masked, ct);
            }
        }

        return sent;
    }

    [LoggerMessage(Level = LogLevel.Warning, Message = "Reminder {ReminderId} via {Channel} failed: {Error}")]
    private static partial void LogSendFailed(ILogger logger, Guid reminderId, string channel, string error);
}
