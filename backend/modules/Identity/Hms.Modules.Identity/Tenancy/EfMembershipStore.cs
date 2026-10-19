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
        var tenantZone = await db.Tenants.AsNoTracking()
            .Where(t => t.Id == tenantId && t.Status == TenantStatus.Active)
            .Select(t => t.TimeZone)
            .FirstOrDefaultAsync(cancellationToken);
        if (tenantZone is null)
        {
            return null;
        }

        var memberships = await db.Memberships.AsNoTracking()
            .Where(m => m.UserId == userId && m.TenantId == tenantId && m.Status == MembershipStatus.Active)
            // A branch-scoped membership counts only while its branch is live (code review MAJ-2;
            // identity.has_tenant_role / current_tenant_ids agree): deleting a branch revokes the
            // tenant-wide roles of staff scoped to it.
            .Where(m => m.BranchId == null || db.Branches.Any(b => b.Id == m.BranchId && !b.IsDeleted))
            .Select(m => new { m.Role, m.BranchId })
            .ToListAsync(cancellationToken);
        if (memberships.Count == 0)
        {
            return null;
        }

        var tenantBranches = await db.Branches.AsNoTracking()
            .Where(b => b.TenantId == tenantId && b.IsActive)
            .Select(b => new { b.Id, b.Timezone })
            .ToListAsync(cancellationToken);

        // Per-branch role map: a (role, branch) pair only counts at that branch; tenant-wide
        // memberships (branch_id null) count at every branch. Never take the union of roles x
        // the union of branches (review M1).
        var rolesByBranch = new Dictionary<Guid, IReadOnlyCollection<string>>();
        foreach (var branch in tenantBranches)
        {
            var atBranch = memberships
                .Where(m => m.BranchId is null || m.BranchId == branch.Id)
                .Select(m => m.Role)
                .Distinct(StringComparer.Ordinal)
                .ToList();
            if (atBranch.Count > 0)
            {
                rolesByBranch[branch.Id] = atBranch;
            }
        }

        var accessible = tenantBranches.Where(b => rolesByBranch.ContainsKey(b.Id)).Select(b => b.Id).ToList();

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

        // Effective zone: branch override, else the tenant zone (identity.branch_time_zone()).
        var timeZones = tenantBranches.Where(b => rolesByBranch.ContainsKey(b.Id)).ToDictionary(b => b.Id, b => Hms.SharedKernel.Time.TenantTimeZones.Effective(b.Timezone, tenantZone));

        return new MembershipGrant(roles, accessible, rolesByBranch, timeZones, tenantZone);
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
