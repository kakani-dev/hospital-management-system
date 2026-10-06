using System.Data.Common;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;

namespace Hms.SharedKernel.Persistence;

/// <summary>
/// Minimal parameterized raw SQL on the DbContext's connection and CURRENT transaction
/// (so it runs under the same RLS role/claims). Used for calling SQL functions.
/// </summary>
public static class RawSql
{
    public static async Task<List<T>> QueryAsync<T>(
        DbContext db, string sql, Func<DbDataReader, T> map, CancellationToken ct, params (string Name, object? Value)[] parameters)
    {
        await using var command = await CreateAsync(db, sql, parameters, ct);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = new List<T>();
        while (await reader.ReadAsync(ct))
        {
            rows.Add(map(reader));
        }

        return rows;
    }

    public static async Task<object?> ScalarAsync(
        DbContext db, string sql, CancellationToken ct, params (string Name, object? Value)[] parameters)
    {
        await using var command = await CreateAsync(db, sql, parameters, ct);
        var value = await command.ExecuteScalarAsync(ct);
        return value is DBNull ? null : value;
    }

    private static async Task<DbCommand> CreateAsync(DbContext db, string sql, (string Name, object? Value)[] parameters, CancellationToken ct)
    {
        var tx = db.Database.CurrentTransaction?.GetDbTransaction()
            ?? throw new InvalidOperationException("Raw SQL must run inside a transaction so RLS claims apply.");
        var connection = db.Database.GetDbConnection();
        if (connection.State != System.Data.ConnectionState.Open)
        {
            await connection.OpenAsync(ct);
        }

        var command = connection.CreateCommand();
        command.Transaction = tx;
        command.CommandText = sql;
        foreach (var (name, value) in parameters)
        {
            var p = command.CreateParameter();
            p.ParameterName = name;
            p.Value = value ?? DBNull.Value;
            command.Parameters.Add(p);
        }

        return command;
    }
}
