using Hms.SharedKernel.Persistence;
using Npgsql;

namespace Hms.Modules.Appointments.Reminders;

// cross-schema: approved — appointment.claim_due_reminders reads patients only via patient.reminder_contact_v1.

public interface IReminderStore
{
    Task<IReadOnlyList<DueReminder>> ClaimAsync(int limit, CancellationToken ct);
    Task CompleteAsync(Guid id, string status, string detail, string recipientMasked, CancellationToken ct);
}

/// <summary>Each call is one short transaction under the scheduling session role (the login role owns nothing).</summary>
public sealed class PostgresReminderStore(NpgsqlDataSource dataSource, DatabaseSessionOptions session) : IReminderStore
{
    public async Task<IReadOnlyList<DueReminder>> ClaimAsync(int limit, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var tx = await connection.BeginTransactionAsync(ct);
        await SetRoleAsync(connection, tx, ct);
        await using var command = new NpgsqlCommand(
            "select reminder_id, tenant_id, appointment_id, kind, channel, recipient, patient_first_name, practitioner_label, " +
            "branch_name, starts_at, time_zone, attempts from appointment.claim_due_reminders(@limit)", connection, tx);
        command.Parameters.AddWithValue("limit", Math.Clamp(limit, 1, 500));
        var rows = new List<DueReminder>();
        await using (var r = await command.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                rows.Add(new DueReminder(
                    r.GetGuid(0), r.GetGuid(1), r.GetGuid(2), r.GetString(3), r.GetString(4),
                    r.IsDBNull(5) ? null : r.GetString(5), r.IsDBNull(6) ? null : r.GetString(6),
                    r.IsDBNull(7) ? null : r.GetString(7), r.IsDBNull(8) ? null : r.GetString(8),
                    r.GetFieldValue<DateTimeOffset>(9), r.IsDBNull(10) ? null : r.GetString(10), r.GetInt16(11)));
            }
        }

        await tx.CommitAsync(ct);
        return rows;
    }

    public async Task CompleteAsync(Guid id, string status, string detail, string recipientMasked, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct);
        await using var tx = await connection.BeginTransactionAsync(ct);
        await SetRoleAsync(connection, tx, ct);
        await using var command = new NpgsqlCommand("select appointment.complete_reminder(@id, @status, @detail, @masked)", connection, tx);
        command.Parameters.AddWithValue("id", id);
        command.Parameters.AddWithValue("status", status);
        command.Parameters.AddWithValue("detail", detail);
        command.Parameters.AddWithValue("masked", recipientMasked);
        await command.ExecuteNonQueryAsync(ct);
        await tx.CommitAsync(ct);
    }

    private async Task SetRoleAsync(NpgsqlConnection connection, NpgsqlTransaction tx, CancellationToken ct)
    {
        await using var command = new NpgsqlCommand("select set_config('role', @role, true)", connection, tx);
        command.Parameters.AddWithValue("role", session.AuthenticatedRole);
        await command.ExecuteNonQueryAsync(ct);
    }
}
