using Hms.Modules.Identity.Domain;
using Hms.Modules.Identity.Persistence;
using Hms.SharedKernel.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Identity.Tenancy;

/// <summary>
/// Reads memberships. On PostgreSQL every call runs in its own transaction, so it executes as
/// the calling user under RLS (the API never reads other users' memberships).
/// </summary>
internal sealed class EfMembershipStore(IdentityDbContext db) : IMembershipStore
{
    public Task<MembershipGrant?> FindActiveGrantAsync(Guid userId, Guid tenantId, Guid? branchId, CancellationToken cancellationToken) =>
        InTransactionAsync(ct => FindGrantCoreAsync(userId, tenantId, branchId, ct), cancellationToken);

    public Task<ActiveContext?> FindDefaultContextAsync(CancellationToken cancellationToken) =>
        InTransactionAsync(
            async ct =>
            {
                if (!db.Database.IsRelational())
                {
                    return null;
                }

                var rows = await RawSql.QueryAsync(
                    db,
                    "select tenant_id, branch_id from identity.my_active_context()",
                    r => new ActiveContext(r.GetGuid(0), r.IsDBNull(1) ? null : r.GetGuid(1)),
                    ct);
                return rows.FirstOrDefault();
            },
            cancellationToken);

    private async Task<MembershipGrant?> FindGrantCoreAsync(Guid userId, Guid tenantId, Guid? branchId, CancellationToken cancellationToken)
    {
        var tenantActive = await db.Tenants.AsNoTracking()
            .AnyAsync(t => t.Id == tenantId && t.Status == TenantStatus.Active, cancellationToken);
        if (!tenantActive)
        {
            return null;
        }

        var memberships = await db.Memberships.AsNoTracking()
            .Where(m => m.UserId == userId && m.TenantId == tenantId && m.Status == MembershipStatus.Active)
            .Select(m => new { m.Role, m.BranchId })
            .ToListAsync(cancellationToken);
        if (memberships.Count == 0)
        {
            return null;
        }

        var tenantBranchIds = await db.Branches.AsNoTracking()
            .Where(b => b.TenantId == tenantId && b.IsActive)
            .Select(b => b.Id)
            .ToListAsync(cancellationToken);

        var accessible = memberships.Any(m => m.BranchId is null)
            ? tenantBranchIds
            : tenantBranchIds.Where(id => memberships.Any(m => m.BranchId == id)).ToList();

        if (branchId is { } requested && !accessible.Contains(requested))
        {
            return null;
        }

        // When a branch is pinned, only roles valid for that branch (or tenant-wide) apply.
        var roles = memberships
            .Where(m => branchId is null || m.BranchId is null || m.BranchId == branchId)
            .Select(m => m.Role)
            .Distinct(StringComparer.Ordinal)
            .ToList();

        return new MembershipGrant(roles, accessible);
    }

    private async Task<T?> InTransactionAsync<T>(Func<CancellationToken, Task<T?>> work, CancellationToken ct)
    {
        if (!db.Database.IsRelational() || db.Database.CurrentTransaction is not null)
        {
            return await work(ct);
        }

        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var result = await work(ct);
        await tx.CommitAsync(ct);
        return result;
    }
}
