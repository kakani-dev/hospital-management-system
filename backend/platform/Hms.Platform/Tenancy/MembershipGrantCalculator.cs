namespace Hms.Platform.Tenancy;

/// <summary>An ACTIVE membership of the current user in one tenant (<c>BranchId</c> null = tenant-wide).</summary>
public sealed record MembershipRow(string Role, Guid? BranchId);

/// <summary>An ACTIVE branch of the tenant; <c>Timezone</c> null = inherits the tenant zone.</summary>
public sealed record BranchRow(Guid Id, string? Timezone);

/// <summary>
/// Pure function that turns the user's active memberships and the tenant's active branches into a
/// <see cref="MembershipGrant"/> (moved verbatim from the Sprint 1 EF store, review M1 semantics).
/// </summary>
public static class MembershipGrantCalculator
{
    /// <returns>null when there is no active membership, or the requested branch is outside the user's branch scope.</returns>
    public static MembershipGrant? Compute(IReadOnlyList<MembershipRow> memberships, IReadOnlyList<BranchRow> tenantBranches, Guid? branchId, string tenantTimeZone)
    {
        ArgumentNullException.ThrowIfNull(memberships);
        ArgumentNullException.ThrowIfNull(tenantBranches);
        if (memberships.Count == 0)
        {
            return null;
        }

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

        // Effective zone: branch override, else the tenant zone (identity.branch_time_zone_v1).
        var timeZones = tenantBranches.Where(b => rolesByBranch.ContainsKey(b.Id))
            .ToDictionary(b => b.Id, b => Hms.SharedKernel.Time.TenantTimeZones.Effective(b.Timezone, tenantTimeZone));

        return new MembershipGrant(roles, accessible, rolesByBranch, timeZones, tenantTimeZone);
    }
}
