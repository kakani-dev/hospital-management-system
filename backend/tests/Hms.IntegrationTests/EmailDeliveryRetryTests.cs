using Hms.Modules.Identity.Email;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Npgsql;
using static Hms.IntegrationTests.HmsApiFactory;

namespace Hms.IntegrationTests;

/// <summary>
/// One outbox event is handed to the sender once, even when the first attempt fails and a later
/// claim redelivers the same event_id (lost ack). The sender is a fake; nothing leaves the process.
/// </summary>
[Trait("Category", "Database")]
public sealed class EmailDeliveryRetryTests
{
    private const string BaseUrl = "https://medicore-hms-three.vercel.app";

    [Fact]
    public async Task One_email_is_sent_per_event_when_delivery_is_retried()
    {
        var token = Guid.NewGuid().ToString("N") + Guid.NewGuid().ToString("N");
        const string recipient = "retry-one@synthetic.example";
        const string hospital = "Synthetic Retry Hospital";
        var (pendingId, eventId) = await EnqueueAsync(recipient, hospital, token);

        var payload = await AdminScalarAsync<string>(
            "select payload::text from messaging.outbox where event_id = @id", ("id", eventId));
        Assert.DoesNotContain(recipient, payload, StringComparison.Ordinal);
        Assert.DoesNotContain(hospital, payload, StringComparison.Ordinal);
        Assert.DoesNotContain(token, payload, StringComparison.Ordinal);
        Assert.DoesNotContain("@", payload, StringComparison.Ordinal);

        await using var dataSource = NpgsqlDataSource.Create(ServiceConnection("identity"));
        var inner = new PostgresEmailOutbox(dataSource);
        var store = new OnlyThisEvent(inner, eventId);
        var sender = new CountingSender();
        var dispatcher = new EmailOutboxDispatcher(
            store,
            sender,
            Options.Create(new EmailDeliveryOptions
            {
                PublicBaseUrl = BaseUrl,
                Dispatcher = new EmailDispatcherOptions { BatchSize = 20, LeaseSeconds = 120, RetryBaseSeconds = 30, DailySendLimit = 10_000 },
            }),
            TimeProvider.System,
            NullLogger<EmailOutboxDispatcher>.Instance);

        for (var i = 0; i < 30 && sender.Failures == 0; i++)
        {
            await dispatcher.RunOnceAsync(CancellationToken.None);
        }

        Assert.Equal(1, sender.Failures);
        Assert.Equal(0, sender.Delivered);

        await AdminAsync(
            "update messaging.outbox set status = 'pending', claimed_by = null, claimed_until = null, available_at = now() - interval '1 second' where event_id = @id",
            ("id", eventId));

        for (var i = 0; i < 5 && sender.Delivered == 0; i++)
        {
            await dispatcher.RunOnceAsync(CancellationToken.None);
        }

        Assert.Equal(1, sender.Delivered);
        Assert.Contains($"{BaseUrl}/invite/{token}", sender.LastText, StringComparison.Ordinal);
        Assert.Equal(1, await AdminScalarAsync<long>("select count(*) from messaging.email_send_receipts where event_id = @id", ("id", eventId)));
        Assert.Equal(1L, await AdminScalarAsync<long>(
            "select count(*) from identity.pending_emails where id = @id and recipient = 'redacted@invalid.local' and variables = '{}'::jsonb and redacted_on is not null",
            ("id", pendingId)));

        await AdminAsync(
            "update messaging.outbox set status = 'pending', claimed_by = null, claimed_until = null, available_at = now() - interval '1 second', processed_at = null where event_id = @id",
            ("id", eventId));
        await dispatcher.RunOnceAsync(CancellationToken.None);

        Assert.Equal(1, sender.Delivered);
        Assert.Equal(1, sender.Failures);
        Assert.Equal(1, await AdminScalarAsync<long>("select count(*) from messaging.email_send_receipts where event_id = @id", ("id", eventId)));
        Assert.Equal("done", await AdminScalarAsync<string>("select status from messaging.outbox where event_id = @id", ("id", eventId)));
    }

    private static async Task<(Guid PendingId, Guid EventId)> EnqueueAsync(string recipient, string hospital, string token)
    {
        await using var connection = await OpenAdminAsync();
        await using var command = new NpgsqlCommand(
            """
            select identity.enqueue_email(
              '11111111-1111-4111-8111-111111111111',
              gen_random_uuid(),
              'invite_link',
              @recipient,
              jsonb_build_object('hospitalName', @hospital, 'role', 'nurse', 'token', @token, 'expiresOn', '2026-12-01T00:00:00Z'))
            """,
            connection);
        command.Parameters.AddWithValue("recipient", recipient);
        command.Parameters.AddWithValue("hospital", hospital);
        command.Parameters.AddWithValue("token", token);
        var pendingId = (Guid)(await command.ExecuteScalarAsync())!;
        var eventId = await AdminScalarAsync<Guid>(
            "select event_id from messaging.outbox where (payload->>'pending_email_id')::uuid = @id",
            ("id", pendingId));
        return (pendingId, eventId);
    }

    private static async Task<NpgsqlConnection> OpenAdminAsync()
    {
        var connection = new NpgsqlConnection(AdminConnection);
        await connection.OpenAsync();
        return connection;
    }

    private static async Task AdminAsync(string sql, params (string Name, object Value)[] parameters)
    {
        await using var connection = await OpenAdminAsync();
        await using var command = new NpgsqlCommand(sql, connection);
        foreach (var (name, value) in parameters)
        {
            command.Parameters.AddWithValue(name, value);
        }

        await command.ExecuteNonQueryAsync();
    }

    private static async Task<T> AdminScalarAsync<T>(string sql, params (string Name, object Value)[] parameters)
    {
        await using var connection = await OpenAdminAsync();
        await using var command = new NpgsqlCommand(sql, connection);
        foreach (var (name, value) in parameters)
        {
            command.Parameters.AddWithValue(name, value);
        }

        var scalar = await command.ExecuteScalarAsync();
        return (T)scalar!;
    }

    private sealed class CountingSender : IEmailSender
    {
        public int Failures { get; private set; }

        public int Delivered { get; private set; }

        public string LastText { get; private set; } = "";

        public Task SendAsync(OutgoingEmail email, CancellationToken cancellationToken)
        {
            if (Failures == 0 && Delivered == 0)
            {
                Failures++;
                throw new IOException("smtp timeout");
            }

            Delivered++;
            LastText = email.TextBody;
            return Task.CompletedTask;
        }
    }

    /// <summary>Other pending mail in the shared test database is released, not sent.</summary>
    private sealed class OnlyThisEvent(IEmailOutbox inner, Guid eventId) : IEmailOutbox
    {
        public Task<int> SendsTodayAsync(CancellationToken cancellationToken) => inner.SendsTodayAsync(cancellationToken);

        public async Task<IReadOnlyList<EmailOutboxMessage>> ClaimAsync(string workerId, int batchSize, TimeSpan lease, CancellationToken cancellationToken)
        {
            var batch = await inner.ClaimAsync(workerId, batchSize, lease, cancellationToken);
            foreach (var other in batch.Where(m => m.EventId != eventId))
            {
                await inner.FailAsync(other.Id, workerId, "held by another test", TimeSpan.FromHours(1), cancellationToken);
            }

            return batch.Where(m => m.EventId == eventId).ToList();
        }

        public Task<bool> AlreadySentAsync(Guid id, CancellationToken cancellationToken) => inner.AlreadySentAsync(id, cancellationToken);

        public Task<PendingEmail?> LoadAsync(Guid pendingEmailId, CancellationToken cancellationToken) => inner.LoadAsync(pendingEmailId, cancellationToken);

        public Task<bool> RecordSentAsync(Guid id, Guid tenantId, CancellationToken cancellationToken) => inner.RecordSentAsync(id, tenantId, cancellationToken);

        public Task RedactAsync(Guid pendingEmailId, CancellationToken cancellationToken) => inner.RedactAsync(pendingEmailId, cancellationToken);

        public Task CompleteAsync(long id, string workerId, CancellationToken cancellationToken) => inner.CompleteAsync(id, workerId, cancellationToken);

        public Task FailAsync(long id, string workerId, string error, TimeSpan retryIn, CancellationToken cancellationToken) =>
            inner.FailAsync(id, workerId, error, retryIn, cancellationToken);
    }
}
