using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;

namespace Hms.Platform.Http;

/// <summary>
/// The status for a branch-bound request the caller may not perform (SPRINT2-CONTRACT v4 §0):
/// a branch of ANOTHER tenant (or unknown) is 404 — indistinguishable from non-existent — while a
/// branch of the caller's own tenant that is outside their scope / role is 403.
/// </summary>
public static class BranchScope
{
    public static async Task<ProblemHttpResult> DenyAsync(DbContext db, ITenantContext tenant, Guid branchId, string forbiddenDetail, CancellationToken ct)
    {
        if (tenant.CanAccessBranch(branchId) || await BelongsToTenantAsync(db, tenant, branchId, ct))
        {
            return HmsProblems.Forbidden(forbiddenDetail);
        }

        return HmsProblems.NotFound("Branch not found.");
    }

    /// <summary>True when the branch is one of the caller's branches or another (RLS-visible) branch of the resolved tenant.</summary>
    public static async Task<bool> ExistsInTenantAsync(DbContext db, ITenantContext tenant, Guid branchId, CancellationToken ct) =>
        tenant.CanAccessBranch(branchId) || await BelongsToTenantAsync(db, tenant, branchId, ct);

    private static async Task<bool> BelongsToTenantAsync(DbContext db, ITenantContext tenant, Guid branchId, CancellationToken ct)
    {
        if (!tenant.IsResolved || branchId == Guid.Empty || !db.Database.IsRelational() || db.Database.CurrentTransaction is null)
        {
            return false;
        }

        // RLS (branches_select_member) only shows branches of the caller's tenants; the tenant filter pins the resolved one.
        var found = await RawSql.ScalarAsync(
            db, "select exists (select 1 from identity.branches where id = @b::uuid and tenant_id = @t::uuid)", ct,
            ("b", branchId), ("t", tenant.TenantId));
        return found is true;
    }
}
