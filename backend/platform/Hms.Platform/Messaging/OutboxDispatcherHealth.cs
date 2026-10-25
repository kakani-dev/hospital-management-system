using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Options;

namespace Hms.Platform.Messaging;

/// <summary>In-process view of the outbox worker. The ready check reports it and stays up when the flag is off.</summary>
public sealed class OutboxDispatcherHealth(IOptions<OutboxOptions> options)
{
    private readonly Lock _gate = new();
    private Snapshot _current = Snapshot.Initial(options.Value);

    public Snapshot Current
    {
        get
        {
            lock (_gate)
            {
                return _current;
            }
        }
    }

    public void RecordPoll(DateTimeOffset at, OutboxBacklog? backlog, bool dryRun, int claimed)
    {
        lock (_gate)
        {
            _current = _current with
            {
                DryRun = dryRun,
                LastPollUtc = at,
                LastClaimed = claimed,
                ConsecutiveFailures = 0,
                Pending = backlog?.Pending ?? _current.Pending,
                Processing = backlog?.Processing ?? _current.Processing,
                Dead = backlog?.Dead ?? _current.Dead,
                StalePending = backlog?.StalePending ?? _current.StalePending,
                OldestPendingSeconds = backlog is null ? _current.OldestPendingSeconds : backlog.OldestPendingSeconds,
            };
        }
    }

    public void RecordFailure(DateTimeOffset at)
    {
        lock (_gate)
        {
            _current = _current with
            {
                LastPollUtc = at,
                ConsecutiveFailures = _current.ConsecutiveFailures + 1,
            };
        }
    }

    public sealed record Snapshot(
        bool Enabled,
        bool DryRun,
        DateTimeOffset? LastPollUtc,
        int LastClaimed,
        int ConsecutiveFailures,
        long Pending,
        long Processing,
        long Dead,
        long StalePending,
        long? OldestPendingSeconds)
    {
        public static Snapshot Initial(OutboxOptions options) =>
            new(options.Enabled, options.DryRun, null, 0, 0, 0, 0, 0, 0, null);
    }
}

public sealed class OutboxDispatcherHealthCheck(OutboxDispatcherHealth health) : IHealthCheck
{
    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        var snapshot = health.Current;
        var data = new Dictionary<string, object>
        {
            ["enabled"] = snapshot.Enabled,
            ["dryRun"] = snapshot.DryRun,
            ["pending"] = snapshot.Pending,
            ["processing"] = snapshot.Processing,
            ["dead"] = snapshot.Dead,
            ["stalePending"] = snapshot.StalePending,
            ["consecutiveFailures"] = snapshot.ConsecutiveFailures,
            ["lastClaimed"] = snapshot.LastClaimed,
        };
        if (snapshot.OldestPendingSeconds is { } age)
        {
            data["oldestPendingSeconds"] = age;
        }

        if (!snapshot.Enabled)
        {
            return Task.FromResult(HealthCheckResult.Healthy("dispatcher off", data));
        }

        if (snapshot.ConsecutiveFailures >= 3)
        {
            return Task.FromResult(HealthCheckResult.Degraded("dispatcher poll is failing", data: data));
        }

        var detail = snapshot.DryRun ? "dry run" : "dispatching";
        return Task.FromResult(HealthCheckResult.Healthy(detail, data));
    }
}
