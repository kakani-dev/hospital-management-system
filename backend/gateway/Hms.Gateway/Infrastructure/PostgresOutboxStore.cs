using Hms.SharedKernel.Messaging;
using Npgsql;

namespace Hms.Gateway.Infrastructure;

/// <summary>
/// messaging.claim_outbox / complete_outbox / fail_outbox (SPRINT2-CONTRACT §4.3). Every call is its
/// own short transaction that starts with <c>SET LOCAL ROLE hms_dispatcher</c>: the API login role
/// owns no privileges itself (fail closed), and hms_dispatcher can only EXECUTE these three functions.
/// </summary>
public sealed class PostgresOutboxStore(NpgsqlDataSource dataSource) : IOutboxStore
{
    internal const string DispatcherRole = "hms_dispatcher";

    public async Task<IReadOnlyList<OutboxMessage>> ClaimAsync(string workerId, int batchSize, TimeSpan lease, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var tx = await connection.BeginTransactionAsync(ct);
        await SetRoleAsync(connection, tx, ct);

        await using var command = new NpgsqlCommand(
            "select id, event_id, tenant_id, aggregate_type, aggregate_id, event_type, payload::text, occurred_at, attempts " +
            "from messaging.claim_outbox(@worker, @batch, @lease)", connection, tx);
        command.Parameters.AddWithValue("worker", workerId);
        command.Parameters.AddWithValue("batch", batchSize);
        command.Parameters.AddWithValue("lease", lease);

        var messages = new List<OutboxMessage>();
        await using (var reader = await command.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                messages.Add(new OutboxMessage(
                    reader.GetInt64(0), reader.GetGuid(1), reader.GetGuid(2), reader.GetString(3), reader.GetGuid(4), reader.GetString(5),
                    reader.GetString(6), reader.GetFieldValue<DateTimeOffset>(7), reader.GetInt32(8)));
            }
        }

        await tx.CommitAsync(ct);
        return messages;
    }

    public Task CompleteAsync(long id, string workerId, CancellationToken ct) =>
        ExecuteAsync("select messaging.complete_outbox(@id, @worker)", ct, ("id", id), ("worker", workerId));

    public Task FailAsync(long id, string workerId, string errorMessage, TimeSpan retryIn, CancellationToken ct) =>
        ExecuteAsync("select messaging.fail_outbox(@id, @worker, @error, @retry)", ct, ("id", id), ("worker", workerId), ("error", errorMessage), ("retry", retryIn));

    private async Task ExecuteAsync(string sql, CancellationToken ct, params (string Name, object Value)[] parameters)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var tx = await connection.BeginTransactionAsync(ct);
        await SetRoleAsync(connection, tx, ct);
        await using var command = new NpgsqlCommand(sql, connection, tx);
        foreach (var (name, value) in parameters)
        {
            command.Parameters.AddWithValue(name, value);
        }

        await command.ExecuteNonQueryAsync(ct);
        await tx.CommitAsync(ct);
    }

    private static async Task SetRoleAsync(NpgsqlConnection connection, NpgsqlTransaction tx, CancellationToken ct)
    {
        await using var command = new NpgsqlCommand($"set local role {DispatcherRole}", connection, tx);
        await command.ExecuteNonQueryAsync(ct);
    }
}
