using System.Data.Common;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace Hms.SharedKernel.Persistence;

/// <summary>
/// At the start of EVERY EF Core transaction, switches the database role to <c>authenticated</c>
/// (or <c>anon</c>) and sets <c>request.jwt.claims</c> from <see cref="DbSessionContext"/>, both
/// transaction-local (works with transaction-mode poolers such as Supavisor :6543).
/// The API's login role is NOINHERIT and owns no privileges, so any query that does not run
/// inside such a transaction is denied by PostgreSQL (fail closed).
/// </summary>
public sealed class RlsTransactionInterceptor(DbSessionContext session) : DbTransactionInterceptor
{
    internal const string Sql =
        "SELECT set_config('role', @role, true), set_config('request.jwt.claims', @claims, true), set_config('request.jwt.claim.sub', @sub, true)";

    public override DbTransaction TransactionStarted(DbConnection connection, TransactionEndEventData eventData, DbTransaction result)
    {
        using var command = CreateCommand(connection, result);
        command.ExecuteNonQuery();
        return result;
    }

    public override async ValueTask<DbTransaction> TransactionStartedAsync(
        DbConnection connection, TransactionEndEventData eventData, DbTransaction result, CancellationToken cancellationToken = default)
    {
        await using var command = CreateCommand(connection, result);
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        return result;
    }

    private DbCommand CreateCommand(DbConnection connection, DbTransaction transaction)
    {
        var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = Sql;
        AddParameter(command, "role", session.IsAuthenticated ? "authenticated" : "anon");
        AddParameter(command, "claims", session.ToClaimsJson());
        AddParameter(command, "sub", session.UserId?.ToString() ?? string.Empty);
        return command;
    }

    private static void AddParameter(DbCommand command, string name, string value)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.Value = value;
        command.Parameters.Add(p);
    }
}
