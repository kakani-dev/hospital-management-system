using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;

namespace Hms.Platform.Http;

// cross-schema: approved — identity.branch_exists_v1 (docs/contracts/db.md). Callers do not read identity.branches.

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

        // Published contract: live branch in the caller's tenant. Soft-deleted branches are absent (404),
        // which matches "not a bookable branch" for every role.
        var found = await RawSql.ScalarAsync(
            db, "select identity.branch_exists_v1(@t::uuid, @b::uuid)", ct,
            ("t", tenant.TenantId), ("b", branchId));
        return found is true;
    }
}
