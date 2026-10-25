namespace Hms.Platform.Messaging;

/// <summary>A claimed row of messaging.outbox (SPRINT2-CONTRACT §4). The payload carries no PHI.</summary>
public sealed record OutboxMessage(
    long Id, Guid EventId, Guid TenantId, string AggregateType, Guid AggregateId, string EventType, string PayloadJson,
    DateTimeOffset OccurredAt, int Attempts);

/// <summary>
/// Consumer side of the transactional outbox. Rows are written ONLY by DB triggers in the same
/// transaction as the business change (D8); the dispatcher claims them with leases
/// (FOR UPDATE SKIP LOCKED, as role hms_dispatcher) and acknowledges each one.
/// </summary>
public interface IOutboxStore
{
    Task<IReadOnlyList<OutboxMessage>> ClaimAsync(string workerId, int batchSize, TimeSpan lease, CancellationToken ct);

    Task CompleteAsync(long id, string workerId, CancellationToken ct);

    Task FailAsync(long id, string workerId, string errorMessage, TimeSpan retryIn, CancellationToken ct);

    /// <summary>True when this service already handed <paramref name="eventId"/> to its publisher.</summary>
    Task<bool> WasDispatchedAsync(Guid eventId, CancellationToken ct);

    /// <summary>Records a successful publish. The tenant id must be the one on the outbox row.</summary>
    Task NoteDispatchedAsync(Guid eventId, Guid tenantId, CancellationToken ct);

    /// <summary>Counts for this service's rows. Does not claim.</summary>
    Task<OutboxBacklog> ReadBacklogAsync(CancellationToken ct);
}

/// <summary>Delivers one event to its consumers. Must be idempotent per <see cref="OutboxMessage.EventId"/> (at-least-once).</summary>
public interface IOutboxPublisher
{
    Task PublishAsync(OutboxMessage message, CancellationToken ct);
}

public sealed record OutboxBacklog(long Pending, long Processing, long Dead, long StalePending, long? OldestPendingSeconds);

public sealed class OutboxOptions
{
    public const string Section = "Outbox:Dispatcher";

    /// <summary>Dead-letter threshold enforced by messaging.fail_outbox. Not a client setting.</summary>
    public const int MaxAttempts = 10;

    /// <summary>Off by default. Turning it on with <see cref="DryRun"/> still does not claim.</summary>
    public bool Enabled { get; set; }

    /// <summary>When true, the worker only reads the backlog. It does not claim, publish, or bump attempts.</summary>
    public bool DryRun { get; set; } = true;

    public int BatchSize { get; set; } = 50;

    public int PollIntervalSeconds { get; set; } = 5;

    public int LeaseSeconds { get; set; } = 30;

    /// <summary>Base retry delay; doubles per attempt (capped at 1 hour).</summary>
    public int RetryBaseSeconds { get; set; } = 30;

    /// <summary>Size of the in-process "already published" set used to skip re-delivery after a lost ack.</summary>
    public int DedupCapacity { get; set; } = 10_000;
}
