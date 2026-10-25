using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Options;

namespace Hms.Modules.Identity.Email;

/// <summary>In-process view of the identity email worker. Ready stays healthy while the flag is off.</summary>
public sealed class EmailDispatcherHealth(IOptions<EmailDeliveryOptions> options)
{
    private readonly Lock _gate = new();
    private Snapshot _current = Snapshot.Initial(options.Value.Dispatcher);

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

    public void RecordPoll(DateTimeOffset at, int claimed)
    {
        lock (_gate)
        {
            _current = _current with
            {
                LastPollUtc = at,
                LastClaimed = claimed,
                ConsecutiveFailures = 0,
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

    public sealed record Snapshot(bool Enabled, DateTimeOffset? LastPollUtc, int LastClaimed, int ConsecutiveFailures)
    {
        public static Snapshot Initial(EmailDispatcherOptions options) => new(options.Enabled, null, 0, 0);
    }
}

public sealed class EmailDispatcherHealthCheck(EmailDispatcherHealth health) : IHealthCheck
{
    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        var snapshot = health.Current;
        var data = new Dictionary<string, object>
        {
            ["enabled"] = snapshot.Enabled,
            ["consecutiveFailures"] = snapshot.ConsecutiveFailures,
            ["lastClaimed"] = snapshot.LastClaimed,
        };
        if (!snapshot.Enabled)
        {
            return Task.FromResult(HealthCheckResult.Healthy("email dispatcher off", data));
        }

        if (snapshot.ConsecutiveFailures >= 3)
        {
            return Task.FromResult(HealthCheckResult.Degraded("email dispatcher poll is failing", data: data));
        }

        return Task.FromResult(HealthCheckResult.Healthy("sending", data));
    }
}
