using System.Text.Json;
using Npgsql;

namespace Hms.IntegrationTests.Pr1Regression;

/// <summary>
/// Shared contracts from /workspace/review-pr1/FIX-PLAN.md ("Shared contracts"), in one place so
/// that a contract change is a one-line edit. These regression tests are written against the
/// contract BEFORE the fix branches merge: they are expected to be red on f756f20.
/// </summary>
internal static class Pr1Contract
{
    /// <summary>FIX-PLAN API: body of the uniform 202 for no-account, invited and already-member.</summary>
    public const string InviteMessage = "If an account exists for that email, an invitation has been sent.";

    /// <summary>FIX-PLAN API: header carrying the resolved tenant id on every response (M3 option b).</summary>
    public const string TenantHeader = "X-Hms-Tenant";

    /// <summary>Contract update 21:16 IST: add-member stays POST /api/v1/members (tenant from the resolved context).</summary>
    public const string Members = "/api/v1/members";

    /// <summary>Contract update: search is POST /api/v1/patients/search {search, page, pageSize}; GET ?search= is 400.</summary>
    public const string PatientSearch = "/api/v1/patients/search";

    public const string MyInvitations = "/api/v1/me/invitations";

    /// <summary>POST /api/v1/me/invitations/{membershipId}/accept -> 204; 404 if it cannot be accepted (e.g. not the invitee).</summary>
    public static string Accept(Guid membershipId) => $"/api/v1/me/invitations/{membershipId}/accept";
}

/// <summary>
/// Wire shape of GET /api/v1/me/invitations: [{membershipId, tenantId, tenantName, branchId, role, invitedAt}]
/// (contract update). Named Pr1* so it never clashes with Backend's InvitationView in Dtos.cs after the merge.
/// </summary>
public sealed record Pr1InvitationView(Guid MembershipId, Guid TenantId, string TenantName, Guid? BranchId, string Role, DateTimeOffset InvitedAt);

public sealed record MembershipRow(Guid Id, Guid? BranchId, string Role, string Status);

public sealed record PatientAuditRow(
    Guid TenantId, Guid RegisteredBranchId, Guid? CreatedBy, Guid? UpdatedBy, DateTimeOffset CreatedOn, DateTimeOffset UpdatedOn, DateTimeOffset? DeletedAt);

/// <summary>
/// Read-back helpers. Assertions read the persisted state as the DB owner (like
/// HmsApiFactory.CreateUserAsync), while every request under test goes through the API, which
/// connects as hms_api_login.
/// </summary>
internal static class Pr1Db
{
    public static async Task<List<MembershipRow>> MembershipsAsync(Guid tenantId, Guid userId)
    {
        await using var conn = new NpgsqlConnection(HmsApiFactory.AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(
            "select id, branch_id, role, status from identity.memberships where tenant_id = @t and user_id = @u order by created_on", conn);
        cmd.Parameters.AddWithValue("t", tenantId);
        cmd.Parameters.AddWithValue("u", userId);
        var rows = new List<MembershipRow>();
        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            rows.Add(new MembershipRow(reader.GetGuid(0), reader.IsDBNull(1) ? null : reader.GetGuid(1), reader.GetString(2), reader.GetString(3)));
        }

        return rows;
    }

    public static async Task<Guid?> PersistedActiveTenantAsync(Guid userId)
    {
        await using var conn = new NpgsqlConnection(HmsApiFactory.AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand("select active_tenant_id from identity.user_profiles where id = @u", conn);
        cmd.Parameters.AddWithValue("u", userId);
        return await cmd.ExecuteScalarAsync() is Guid g ? g : null;
    }

    /// <summary>
    /// The tenant the custom access token hook would stamp on the user's NEXT token, executed as
    /// supabase_auth_admin exactly like tests/mock-auth/server.mjs does.
    /// </summary>
    public static async Task<string?> HookTenantClaimAsync(Guid userId)
    {
        await using var conn = new NpgsqlConnection(HmsApiFactory.AdminConnection);
        await conn.OpenAsync();
        await using var tx = await conn.BeginTransactionAsync();
        await using (var role = new NpgsqlCommand("set local role supabase_auth_admin", conn, tx))
        {
            await role.ExecuteNonQueryAsync();
        }

        await using var cmd = new NpgsqlCommand("select identity.custom_access_token_hook(@event::jsonb)::text", conn, tx);
        cmd.Parameters.AddWithValue("event", JsonSerializer.Serialize(new
        {
            user_id = userId,
            claims = new { sub = userId, role = "authenticated", aud = "authenticated" },
            authentication_method = "password",
        }));
        var json = (string)(await cmd.ExecuteScalarAsync())!;
        await tx.CommitAsync();
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.GetProperty("claims").TryGetProperty("tenant_id", out var t) ? t.GetString() : null;
    }

    public static async Task<PatientAuditRow?> PatientAuditAsync(Guid patientId)
    {
        await using var conn = new NpgsqlConnection(HmsApiFactory.AdminConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(
            "select tenant_id, registered_branch_id, created_by, updated_by, created_on, updated_on, deleted_at from patient.patients where id = @id", conn);
        cmd.Parameters.AddWithValue("id", patientId);
        await using var reader = await cmd.ExecuteReaderAsync();
        if (!await reader.ReadAsync())
        {
            return null;
        }

        return new PatientAuditRow(
            reader.GetGuid(0),
            reader.GetGuid(1),
            reader.IsDBNull(2) ? null : reader.GetGuid(2),
            reader.IsDBNull(3) ? null : reader.GetGuid(3),
            reader.GetFieldValue<DateTimeOffset>(4),
            reader.GetFieldValue<DateTimeOffset>(5),
            reader.IsDBNull(6) ? null : reader.GetFieldValue<DateTimeOffset>(6));
    }

    /// <summary>
    /// Runs <paramref name="body"/> on a raw hms_api_login connection inside a transaction set up
    /// exactly like RlsTransactionInterceptor does for API requests (SET LOCAL ROLE authenticated +
    /// transaction-local request.jwt.claims), then ROLLS BACK. Used for defense-in-depth checks
    /// that bypass the API's own C# authorization.
    /// </summary>
    public static async Task AsApiRoleAsync(Guid userId, Guid tenantId, Func<NpgsqlConnection, NpgsqlTransaction, Task> body)
    {
        await using var conn = new NpgsqlConnection(HmsApiFactory.ApiConnection);
        await conn.OpenAsync();
        await using var tx = await conn.BeginTransactionAsync();
        await using (var setup = new NpgsqlCommand(
            "select set_config('role', 'authenticated', true), set_config('request.jwt.claims', @claims, true), set_config('request.jwt.claim.sub', @sub, true)",
            conn,
            tx))
        {
            setup.Parameters.AddWithValue("claims", JsonSerializer.Serialize(new Dictionary<string, object>
            {
                ["sub"] = userId, ["role"] = "authenticated", ["aud"] = "authenticated", ["tenant_id"] = tenantId,
            }));
            setup.Parameters.AddWithValue("sub", userId.ToString());
            await setup.ExecuteNonQueryAsync();
        }

        try
        {
            await body(conn, tx);
        }
        finally
        {
            await tx.RollbackAsync();
        }
    }

    public static string NewMrn(string prefix) => $"{prefix}-{Guid.NewGuid():N}"[..20];
}
