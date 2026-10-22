using System.Text.RegularExpressions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Hms.Modules.Identity.Email;

/// <summary>
/// Claims identity email events, sends one message per <c>event_id</c>, then acks the outbox row.
/// A later claim of the same event (lost ack, or a retry after the receipt was written) does not
/// send again. The legacy host does not register this worker.
/// </summary>
public sealed partial class EmailOutboxDispatcher(
    IEmailOutbox store,
    IEmailSender sender,
    IOptions<EmailDeliveryOptions> options,
    TimeProvider clock,
    ILogger<EmailOutboxDispatcher> logger) : BackgroundService
{
    private DateTimeOffset _limitLoggedAt = DateTimeOffset.MinValue;

    public string WorkerId { get; } = Truncate($"{Environment.MachineName}:{Environment.ProcessId}:{Guid.NewGuid():N}", 200);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var dispatcher = options.Value.Dispatcher;
        if (!dispatcher.Enabled)
        {
            LogDisabled(logger);
            return;
        }

        LogStarted(logger, WorkerId);
        while (!stoppingToken.IsCancellationRequested)
        {
            int handled;
            try
            {
                handled = await RunOnceAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
#pragma warning disable CA1031 // the loop must survive SMTP and database outages
            catch (Exception ex)
#pragma warning restore CA1031
            {
                LogPollFailed(logger, ex.GetType().Name);
                handled = 0;
            }

            if (handled < Math.Max(dispatcher.BatchSize, 1))
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, dispatcher.PollIntervalSeconds)), clock, stoppingToken);
            }
        }
    }

    /// <summary>One claim / send / ack round. Returns how many rows were claimed.</summary>
    public async Task<int> RunOnceAsync(CancellationToken cancellationToken)
    {
        var dispatcher = options.Value.Dispatcher;
        var limit = Math.Max(dispatcher.DailySendLimit, 1);
        if (await store.SendsTodayAsync(cancellationToken) >= limit)
        {
            var now = clock.GetUtcNow();
            if (now - _limitLoggedAt > TimeSpan.FromMinutes(15))
            {
                _limitLoggedAt = now;
                LogDailyLimit(logger, limit);
            }

            return 0;
        }

        var batch = await store.ClaimAsync(
            WorkerId,
            Math.Clamp(dispatcher.BatchSize, 1, 500),
            TimeSpan.FromSeconds(Math.Clamp(dispatcher.LeaseSeconds, 1, 3600)),
            cancellationToken);
        foreach (var message in batch)
        {
            try
            {
                await DeliverAsync(message, cancellationToken);
                await store.CompleteAsync(message.Id, WorkerId, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
#pragma warning disable CA1031 // one message must not stop the batch
            catch (Exception ex)
#pragma warning restore CA1031
            {
                var retryIn = RetryDelay(message.Attempts, dispatcher.RetryBaseSeconds);
                LogSendFailed(logger, message.EventId, message.TemplateKey, message.Attempts, ex.GetType().Name);
                await store.FailAsync(message.Id, WorkerId, SafeError(ex), retryIn, cancellationToken);
            }
        }

        return batch.Count;
    }

    private async Task DeliverAsync(EmailOutboxMessage message, CancellationToken cancellationToken)
    {
        if (await store.AlreadySentAsync(message.EventId, cancellationToken))
        {
            await store.RedactAsync(message.PendingEmailId, cancellationToken);
            LogDuplicateSkipped(logger, message.EventId, message.TemplateKey);
            return;
        }

        var pending = await store.LoadAsync(message.PendingEmailId, cancellationToken);
        if (pending is null)
        {
            LogSuppressed(logger, message.EventId, message.TemplateKey);
            return;
        }

        var rendered = EmailTemplates.Render(pending.TemplateKey, pending.Variables, options.Value.PublicBaseUrl);
        await sender.SendAsync(new OutgoingEmail(pending.Recipient, rendered.Subject, rendered.TextBody, rendered.HtmlBody), cancellationToken);
        if (!await store.RecordSentAsync(message.EventId, message.TenantId, cancellationToken))
        {
            LogDuplicateSkipped(logger, message.EventId, message.TemplateKey);
        }

        await store.RedactAsync(message.PendingEmailId, cancellationToken);
    }

    internal static string SafeError(Exception exception)
    {
        var text = EmailAddress().Replace($"{exception.GetType().Name}: {exception.Message}", "[redacted]");
        return Truncate(text, 500);
    }

    internal static TimeSpan RetryDelay(int attempts, int baseSeconds)
    {
        var exponent = Math.Clamp(attempts - 1, 0, 16);
        var seconds = Math.Min(Math.Max(baseSeconds, 1) * Math.Pow(2, exponent), 3600);
        return TimeSpan.FromSeconds(seconds);
    }

    private static string Truncate(string value, int max) => value.Length <= max ? value : value[..max];

    [GeneratedRegex(@"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", RegexOptions.CultureInvariant)]
    private static partial Regex EmailAddress();

    [LoggerMessage(Level = LogLevel.Information, Message = "Email dispatcher disabled (Email:Dispatcher:Enabled=false).")]
    private static partial void LogDisabled(ILogger logger);

    [LoggerMessage(Level = LogLevel.Information, Message = "Email dispatcher {WorkerId} started.")]
    private static partial void LogStarted(ILogger logger, string workerId);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Email outbox poll failed ({ErrorType}); retrying after the poll interval.")]
    private static partial void LogPollFailed(ILogger logger, string errorType);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Email event {EventId} ({TemplateKey}) failed on attempt {Attempts} ({ErrorType}).")]
    private static partial void LogSendFailed(ILogger logger, Guid eventId, string templateKey, int attempts, string errorType);

    [LoggerMessage(Level = LogLevel.Information, Message = "Email event {EventId} ({TemplateKey}) already sent; acknowledging without a second message.")]
    private static partial void LogDuplicateSkipped(ILogger logger, Guid eventId, string templateKey);

    [LoggerMessage(Level = LogLevel.Information, Message = "Email event {EventId} ({TemplateKey}) was revoked before delivery; acknowledging without sending.")]
    private static partial void LogSuppressed(ILogger logger, Guid eventId, string templateKey);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Email daily send limit {Limit} reached; leaving events pending until the next UTC day.")]
    private static partial void LogDailyLimit(ILogger logger, int limit);
}
