using Hms.Modules.Identity.Domain;
using Hms.Modules.Identity.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Identity.Tenancy;

internal sealed class EfMembershipStore(IdentityDbContext db) : IMembershipStore
{
    public async Task<MembershipGrant?> FindActiveGrantAsync(Guid userId, Guid tenantId, Guid? branchId, CancellationToken cancellationToken)
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
            .Where(b => b.TenantId == tenantId)
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
}
