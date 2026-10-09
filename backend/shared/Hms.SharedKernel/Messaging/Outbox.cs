namespace Hms.SharedKernel.Messaging;

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
}

/// <summary>Delivers one event to its consumers. Must be idempotent per <see cref="OutboxMessage.EventId"/> (at-least-once).</summary>
public interface IOutboxPublisher
{
    Task PublishAsync(OutboxMessage message, CancellationToken ct);
}

public sealed class OutboxOptions
{
    public const string Section = "Outbox:Dispatcher";

    /// <summary>Off by default until the outbox migration and the hms_dispatcher role exist in the target DB.</summary>
    public bool Enabled { get; set; }

    public int BatchSize { get; set; } = 50;

    public int PollIntervalSeconds { get; set; } = 5;

    public int LeaseSeconds { get; set; } = 30;

    /// <summary>Base retry delay; doubles per attempt (capped at 1 hour).</summary>
    public int RetryBaseSeconds { get; set; } = 30;

    /// <summary>Size of the in-process "already published" set used to skip re-delivery after a lost ack.</summary>
    public int DedupCapacity { get; set; } = 10_000;
}
