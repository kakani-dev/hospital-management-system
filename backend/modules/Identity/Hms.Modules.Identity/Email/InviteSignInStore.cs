using Npgsql;

namespace Hms.Modules.Identity.Email;

/// <summary>
/// Issues and checks invite sign-in codes as <c>hms_mailer</c>. The raw code stays in
/// <c>identity.pending_emails</c> until the worker sends it. Callers only see the expiry, or the
/// invited email after a correct code.
/// </summary>
public sealed class InviteSignInStore(NpgsqlDataSource dataSource) : IInviteSignInStore
{
    public async Task<DateTimeOffset> IssueAsync(string token, CancellationToken cancellationToken)
    {
        var value = await ScalarAsync("select identity.issue_invite_sign_in_code(@token)", cancellationToken, ("token", token));
        return value switch
        {
            DateTimeOffset expires => expires,
            DateTime expires => new DateTimeOffset(DateTime.SpecifyKind(expires, DateTimeKind.Utc)),
            _ => throw new InvalidOperationException("Sign-in code expiry was not returned."),
        };
    }

    public async Task<string> ConsumeAsync(string token, string code, CancellationToken cancellationToken)
    {
        var value = await ScalarAsync(
            "select identity.consume_invite_sign_in_code(@token, @code)",
            cancellationToken,
            ("token", token),
            ("code", code));
        if (value is null or DBNull)
        {
            throw new InviteSignInRejectedException();
        }

        return value as string ?? throw new InvalidOperationException("Sign-in code check did not return an address.");
    }

    private async Task<object?> ScalarAsync(string sql, CancellationToken cancellationToken, params (string Name, object Value)[] parameters)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken);
        await using var tx = await connection.BeginTransactionAsync(cancellationToken);
        await using (var role = new NpgsqlCommand($"set local role {PostgresEmailOutbox.MailerRole}", connection, tx))
        {
            await role.ExecuteNonQueryAsync(cancellationToken);
        }

        await using var command = new NpgsqlCommand(sql, connection, tx);
        foreach (var (name, value) in parameters)
        {
            command.Parameters.AddWithValue(name, value);
        }

        var result = await command.ExecuteScalarAsync(cancellationToken);
        await tx.CommitAsync(cancellationToken);
        return result;
    }
}

/// <summary>The code did not match, or it was already used. The database transaction has committed.</summary>
public sealed class InviteSignInRejectedException : Exception
{
    public InviteSignInRejectedException()
        : base("Sign-in code is not valid.")
    {
    }
}

public interface IInviteSignInStore
{
    Task<DateTimeOffset> IssueAsync(string token, CancellationToken cancellationToken);

    /// <returns>The invited email. The code is burned, including after five mismatches.</returns>
    Task<string> ConsumeAsync(string token, string code, CancellationToken cancellationToken);
}
