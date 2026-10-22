using System.Text.Json;
using Hms.SharedKernel.Persistence;
using Npgsql;

namespace Hms.Platform.Tenancy;

/// <summary>
/// Membership reads for tenant resolution in ANY service, through identity's PUBLISHED SQL surface
/// (MICROSERVICES-PLAN.md §3.1): <c>identity.my_tenant_grant_v1(tenant)</c> and
/// <c>identity.my_active_context()</c>. No service needs identity's EF model.
/// Every call is its own short transaction that first switches to the calling user exactly like
/// <see cref="RlsTransactionInterceptor"/> (role <c>authenticated</c> + JWT claims, transaction-local),
/// so the reads run under RLS as that user.
/// </summary>
public sealed class NpgsqlMembershipStore(
    NpgsqlDataSource dataSource,
    DbSessionContext session,
    DatabaseSessionOptions? options = null) : IMembershipStore
{
    // cross-schema: approved — identity.my_tenant_grant_v1 and identity.my_active_context (docs/contracts/db.md).
    private readonly string _authenticatedRole = options?.AuthenticatedRole ?? DatabaseSessionOptions.DefaultRole;
    internal const string GrantSql = "select identity.my_tenant_grant_v1(@tenant)::text";
    internal const string DefaultContextSql = "select tenant_id, branch_id from identity.my_active_context()";

    public async Task<MembershipGrant?> FindActiveGrantAsync(Guid userId, Guid tenantId, Guid? branchId, CancellationToken cancellationToken)
    {
        if (session.UserId != userId)
        {
            // The DB function answers for the session user only; never ask on behalf of someone else.
            return null;
        }

        var json = await InUserTransactionAsync(
            async (connection, tx, ct) =>
            {
                await using var command = new NpgsqlCommand(GrantSql, connection, tx);
                command.Parameters.AddWithValue("tenant", tenantId);
                return await command.ExecuteScalarAsync(ct).ConfigureAwait(false) as string;
            },
            cancellationToken).ConfigureAwait(false);

        return json is null ? null : Parse(json, branchId);
    }

    public Task<ActiveContext?> FindDefaultContextAsync(CancellationToken cancellationToken) =>
        InUserTransactionAsync<ActiveContext?>(
            async (connection, tx, ct) =>
            {
                await using var command = new NpgsqlCommand(DefaultContextSql, connection, tx);
                await using var reader = await command.ExecuteReaderAsync(ct).ConfigureAwait(false);
                return await reader.ReadAsync(ct).ConfigureAwait(false)
                    ? new ActiveContext(reader.GetGuid(0), reader.IsDBNull(1) ? null : reader.GetGuid(1))
                    : null;
            },
            cancellationToken);

    /// <summary>Parses the <c>my_tenant_grant_v1</c> document: {"tenant_time_zone","memberships":[{role,branch_id}],"branches":[{id,timezone}]}.</summary>
    internal static MembershipGrant? Parse(string json, Guid? branchId)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var memberships = root.GetProperty("memberships").EnumerateArray()
            .Select(m => new MembershipRow(
                m.GetProperty("role").GetString()!,
                m.GetProperty("branch_id").ValueKind == JsonValueKind.Null ? null : m.GetProperty("branch_id").GetGuid()))
            .ToList();
        var branches = root.GetProperty("branches").EnumerateArray()
            .Select(b => new BranchRow(b.GetProperty("id").GetGuid(), b.GetProperty("timezone").GetString()))
            .ToList();
        var tenantZone = root.TryGetProperty("tenant_time_zone", out var tz) ? tz.GetString() : null;
        if (string.IsNullOrEmpty(tenantZone))
        {
            // Required since 20261012090100; a missing zone must never silently become UTC.
            throw new Hms.SharedKernel.Time.MissingTimeZoneException();
        }

        return MembershipGrantCalculator.Compute(memberships, branches, branchId, tenantZone);
    }

    private async Task<T> InUserTransactionAsync<T>(Func<NpgsqlConnection, NpgsqlTransaction, CancellationToken, Task<T>> work, CancellationToken ct)
    {
        await using var connection = await dataSource.OpenConnectionAsync(ct).ConfigureAwait(false);
        await using var tx = await connection.BeginTransactionAsync(ct).ConfigureAwait(false);
        await using (var setup = new NpgsqlCommand(RlsTransactionInterceptor.Sql, connection, tx))
        {
            setup.Parameters.AddWithValue("role", session.IsAuthenticated ? _authenticatedRole : "anon");
            setup.Parameters.AddWithValue("claims", session.ToClaimsJson());
            setup.Parameters.AddWithValue("sub", session.UserId?.ToString() ?? string.Empty);
            await setup.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }

        var result = await work(connection, tx, ct).ConfigureAwait(false);
        await tx.CommitAsync(ct).ConfigureAwait(false);
        return result;
    }
}
