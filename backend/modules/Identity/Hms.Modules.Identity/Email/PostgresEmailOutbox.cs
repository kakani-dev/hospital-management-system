using System.Text.Json;
using Npgsql;

namespace Hms.Modules.Identity.Email;

// cross-schema: approved — messaging.claim_email_outbox / complete_outbox / fail_outbox as hms_mailer.

/// <summary>
/// Claims <c>email_message</c> rows as <c>hms_mailer</c>. The identity login can assume that role;
/// the legacy <c>hms_api</c> login cannot (B1). Scheduling keeps <c>hms_dispatcher</c> and does not
/// see these rows.
/// </summary>
public sealed class PostgresEmailOutbox(NpgsqlDataSource dataSource) : IEmailOutbox
{
    internal const string MailerRole = "hms_mailer";

    public async Task<int> SendsTodayAsync(CancellationToken cancellationToken)
    {
        var value = await ScalarAsync("select messaging.email_sends_today()", cancellationToken);
        return value is int count ? count : Convert.ToInt32(value, System.Globalization.CultureInfo.InvariantCulture);
    }

    public async Task<IReadOnlyList<EmailOutboxMessage>> ClaimAsync(string workerId, int batchSize, TimeSpan lease, CancellationToken cancellationToken)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken);
        await using var tx = await connection.BeginTransactionAsync(cancellationToken);
        await SetRoleAsync(connection, tx, cancellationToken);
        await using var command = new NpgsqlCommand(
            "select id, event_id, tenant_id, payload::text, attempts from messaging.claim_email_outbox(@worker, @batch, @lease)",
            connection, tx);
        command.Parameters.AddWithValue("worker", workerId);
        command.Parameters.AddWithValue("batch", batchSize);
        command.Parameters.AddWithValue("lease", lease);

        var messages = new List<EmailOutboxMessage>();
        await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                messages.Add(Parse(reader.GetInt64(0), reader.GetGuid(1), reader.GetGuid(2), reader.GetString(3), reader.GetInt32(4)));
            }
        }

        await tx.CommitAsync(cancellationToken);
        return messages;
    }

    public async Task<bool> AlreadySentAsync(Guid eventId, CancellationToken cancellationToken)
    {
        var value = await ScalarAsync("select messaging.email_already_sent(@id)", cancellationToken, ("id", eventId));
        return value is true;
    }

    public async Task<PendingEmail?> LoadAsync(Guid pendingEmailId, CancellationToken cancellationToken)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken);
        await using var tx = await connection.BeginTransactionAsync(cancellationToken);
        await SetRoleAsync(connection, tx, cancellationToken);
        await using var command = new NpgsqlCommand(
            "select template_key, recipient, variables::text from identity.load_pending_email(@id)",
            connection, tx);
        command.Parameters.AddWithValue("id", pendingEmailId);
        PendingEmail? pending = null;
        await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
        {
            if (await reader.ReadAsync(cancellationToken))
            {
                using var document = JsonDocument.Parse(reader.GetString(2));
                pending = new PendingEmail(reader.GetString(0), reader.GetString(1), document.RootElement.Clone());
            }
        }

        await tx.CommitAsync(cancellationToken);
        return pending;
    }

    public async Task<bool> RecordSentAsync(Guid eventId, Guid tenantId, CancellationToken cancellationToken)
    {
        var value = await ScalarAsync(
            "select messaging.record_email_sent(@id, @tenant)",
            cancellationToken,
            ("id", eventId),
            ("tenant", tenantId));
        return value is true;
    }

    public Task RedactAsync(Guid pendingEmailId, CancellationToken cancellationToken) =>
        ExecuteAsync("select identity.redact_pending_email(@id)", cancellationToken, ("id", pendingEmailId));

    public Task CompleteAsync(long id, string workerId, CancellationToken cancellationToken) =>
        ExecuteAsync("select messaging.complete_outbox(@id, @worker)", cancellationToken, ("id", id), ("worker", workerId));

    public Task FailAsync(long id, string workerId, string failure, TimeSpan retryIn, CancellationToken cancellationToken) =>
        ExecuteAsync(
            "select messaging.fail_outbox(@id, @worker, @error, @retry)",
            cancellationToken,
            ("id", id),
            ("worker", workerId),
            ("error", failure),
            ("retry", retryIn));

    internal static EmailOutboxMessage Parse(long id, Guid eventId, Guid tenantId, string payloadJson, int attempts)
    {
        try
        {
            using var document = JsonDocument.Parse(payloadJson);
            var root = document.RootElement;
            if (!root.TryGetProperty("pending_email_id", out var pending)
                || !Guid.TryParse(pending.GetString(), out var pendingId)
                || !root.TryGetProperty("template_key", out var template)
                || string.IsNullOrWhiteSpace(template.GetString()))
            {
                throw new InvalidOperationException("Email outbox payload is missing pending_email_id or template_key.");
            }

            return new EmailOutboxMessage(id, eventId, tenantId, pendingId, template.GetString()!, attempts);
        }
        catch (JsonException)
        {
            throw new InvalidOperationException("Email outbox payload is not valid.");
        }
    }

    private async Task<object?> ScalarAsync(string sql, CancellationToken cancellationToken, params (string Name, object Value)[] parameters)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken);
        await using var tx = await connection.BeginTransactionAsync(cancellationToken);
        await SetRoleAsync(connection, tx, cancellationToken);
        await using var command = new NpgsqlCommand(sql, connection, tx);
        foreach (var (name, value) in parameters)
        {
            command.Parameters.AddWithValue(name, value);
        }

        var result = await command.ExecuteScalarAsync(cancellationToken);
        await tx.CommitAsync(cancellationToken);
        return result;
    }

    private async Task ExecuteAsync(string sql, CancellationToken cancellationToken, params (string Name, object Value)[] parameters)
    {
        await ScalarAsync(sql, cancellationToken, parameters);
    }

    private static async Task SetRoleAsync(NpgsqlConnection connection, NpgsqlTransaction tx, CancellationToken cancellationToken)
    {
        await using var command = new NpgsqlCommand($"set local role {MailerRole}", connection, tx);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
