using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Hms.Platform.Messaging;

/// <summary>
/// Sprint 2 dispatcher skeleton: claim a batch, publish each event, then complete or fail it (with
/// exponential back-off). Delivery is at-least-once; events whose ack was lost are re-claimed after
/// the lease expires and are de-duplicated on <c>event_id</c> here (bounded in-process set) and by
/// consumers. Several instances may run: SKIP LOCKED leases keep them from double-claiming.
/// </summary>
public sealed partial class OutboxDispatcher(
    IOutboxStore store,
    IOutboxPublisher publisher,
    IOptions<OutboxOptions> options,
    TimeProvider clock,
    ILogger<OutboxDispatcher> logger,
    OutboxDispatcherHealth? health = null) : BackgroundService
{
    private readonly OutboxDispatcherHealth _health = health ?? new OutboxDispatcherHealth(options);
    private readonly RecentEventIds _published = new(Math.Max(options.Value.DedupCapacity, 1));

    public string WorkerId { get; } = Truncate($"{Environment.MachineName}:{Environment.ProcessId}:{Guid.NewGuid():N}", 200);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var opts = options.Value;
        if (!opts.Enabled)
        {
            LogDisabled(logger);
            return;
        }

        LogStarted(logger, WorkerId, opts.BatchSize);
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
#pragma warning disable CA1031 // the loop must survive DB outages; the error is logged and retried
            catch (Exception ex)
#pragma warning restore CA1031
            {
                LogPollFailed(logger, ex);
                _health.RecordFailure(clock.GetUtcNow());
                handled = 0;
            }

            // A full batch means there is probably more: poll again immediately.
            if (handled < opts.BatchSize)
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Max(1, opts.PollIntervalSeconds)), clock, stoppingToken).ConfigureAwait(false);
            }
        }
    }

    /// <summary>One claim/publish/ack round. Returns the number of claimed messages.</summary>
    public async Task<int> RunOnceAsync(CancellationToken ct)
    {
        var opts = options.Value;
        if (opts.DryRun)
        {
            var backlog = await store.ReadBacklogAsync(ct).ConfigureAwait(false);
            _health.RecordPoll(clock.GetUtcNow(), backlog, dryRun: true, claimed: 0);
            LogDryRun(logger, backlog.Pending, backlog.StalePending, backlog.Dead);
            return 0;
        }

        var batch = await store.ClaimAsync(WorkerId, Math.Clamp(opts.BatchSize, 1, 500), TimeSpan.FromSeconds(Math.Clamp(opts.LeaseSeconds, 1, 3600)), ct).ConfigureAwait(false);
        foreach (var message in batch)
        {
            try
            {
                var already = await store.WasDispatchedAsync(message.EventId, ct).ConfigureAwait(false);
                if (already || _published.Contains(message.EventId))
                {
                    LogDuplicateSkipped(logger, message.EventId, message.EventType);
                    if (!already)
                    {
                        await store.NoteDispatchedAsync(message.EventId, message.TenantId, ct).ConfigureAwait(false);
                    }
                }
                else
                {
                    await publisher.PublishAsync(message, ct).ConfigureAwait(false);
                    _published.Add(message.EventId);
                    await store.NoteDispatchedAsync(message.EventId, message.TenantId, ct).ConfigureAwait(false);
                }

                await store.CompleteAsync(message.Id, WorkerId, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw; // lease expires and the row is re-claimed later
            }
#pragma warning disable CA1031 // one poison message must not stop the batch
            catch (Exception ex)
#pragma warning restore CA1031
            {
                var retryIn = RetryDelay(message.Attempts, opts.RetryBaseSeconds);
                LogPublishFailed(logger, ex, message.EventId, message.EventType, message.Attempts);
                await store.FailAsync(message.Id, WorkerId, Truncate($"{ex.GetType().Name}: {ex.Message}", 2000), retryIn, ct).ConfigureAwait(false);
            }
        }

        _health.RecordPoll(clock.GetUtcNow(), null, dryRun: false, claimed: batch.Count);
        return batch.Count;
    }

    internal static TimeSpan RetryDelay(int attempts, int baseSeconds)
    {
        var exponent = Math.Clamp(attempts - 1, 0, 16);
        var seconds = Math.Min(Math.Max(baseSeconds, 1) * Math.Pow(2, exponent), 3600);
        return TimeSpan.FromSeconds(seconds);
    }

    private static string Truncate(string value, int max) => value.Length <= max ? value : value[..max];

    [LoggerMessage(Level = LogLevel.Information, Message = "Outbox dispatcher disabled (Outbox:Dispatcher:Enabled=false).")]
    private static partial void LogDisabled(ILogger logger);

    [LoggerMessage(Level = LogLevel.Information, Message = "Outbox dry run: {Pending} pending, {StalePending} stale, {Dead} dead. Nothing was claimed.")]
    private static partial void LogDryRun(ILogger logger, long pending, long stalePending, long dead);

    [LoggerMessage(Level = LogLevel.Information, Message = "Outbox dispatcher {WorkerId} started (batch {BatchSize}).")]
    private static partial void LogStarted(ILogger logger, string workerId, int batchSize);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Outbox poll failed; retrying after the poll interval.")]
    private static partial void LogPollFailed(ILogger logger, Exception ex);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Publishing outbox event {EventId} ({EventType}) failed on attempt {Attempts}.")]
    private static partial void LogPublishFailed(ILogger logger, Exception ex, Guid eventId, string eventType, int attempts);

    [LoggerMessage(Level = LogLevel.Information, Message = "Outbox event {EventId} ({EventType}) already published by this worker; acknowledging without re-publishing.")]
    private static partial void LogDuplicateSkipped(ILogger logger, Guid eventId, string eventType);

    /// <summary>Bounded FIFO set of recently published event ids.</summary>
    private sealed class RecentEventIds(int capacity)
    {
        private readonly HashSet<Guid> _set = [];
        private readonly Queue<Guid> _order = new();
        private readonly Lock _gate = new();

        public bool Contains(Guid id)
        {
            lock (_gate)
            {
                return _set.Contains(id);
            }
        }

        public void Add(Guid id)
        {
            lock (_gate)
            {
                if (!_set.Add(id))
                {
                    return;
                }

                _order.Enqueue(id);
                while (_order.Count > capacity)
                {
                    _set.Remove(_order.Dequeue());
                }
            }
        }
    }
}

/// <summary>Sprint 2 publisher: structured log line with ids and type only (never the payload).</summary>
public sealed partial class LoggingOutboxPublisher(ILogger<LoggingOutboxPublisher> logger) : IOutboxPublisher
{
    public Task PublishAsync(OutboxMessage message, CancellationToken ct)
    {
        LogPublished(logger, message.EventId, message.EventType, message.AggregateType, message.AggregateId, message.TenantId);
        return Task.CompletedTask;
    }

    [LoggerMessage(Level = LogLevel.Information, Message = "Outbox event {EventId} {EventType} for {AggregateType} {AggregateId} (tenant {TenantId}) published.")]
    private static partial void LogPublished(ILogger logger, Guid eventId, string eventType, string aggregateType, Guid aggregateId, Guid tenantId);
}
