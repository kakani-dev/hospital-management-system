using Hms.SharedKernel.Domain;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace Hms.SharedKernel.Persistence;

/// <summary>
/// Enforces tenant ownership on write:
///  * new tenant-owned rows always get the RESOLVED tenant id (whatever the caller set is overwritten);
///  * tenant_id can never be modified;
///  * writing tenant-owned rows without a resolved tenant throws.
/// </summary>
public sealed class TenantSaveChangesInterceptor(ITenantContext tenantContext, TimeProvider timeProvider) : SaveChangesInterceptor
{
    public override InterceptionResult<int> SavingChanges(DbContextEventData eventData, InterceptionResult<int> result)
    {
        Apply(eventData.Context);
        return base.SavingChanges(eventData, result);
    }

    public override ValueTask<InterceptionResult<int>> SavingChangesAsync(
        DbContextEventData eventData,
        InterceptionResult<int> result,
        CancellationToken cancellationToken = default)
    {
        Apply(eventData.Context);
        return base.SavingChangesAsync(eventData, result, cancellationToken);
    }

    private void Apply(DbContext? context)
    {
        if (context is null)
        {
            return;
        }

        var now = timeProvider.GetUtcNow();
        foreach (var entry in context.ChangeTracker.Entries())
        {
            if (entry.Entity is ITenantOwned owned)
            {
                switch (entry.State)
                {
                    case EntityState.Added:
                        owned.TenantId = tenantContext.TenantId; // throws if unresolved
                        break;
                    case EntityState.Modified or EntityState.Deleted:
                        var original = entry.Property(nameof(ITenantOwned.TenantId)).OriginalValue;
                        if (!Equals(original, tenantContext.TenantId) || !Equals(owned.TenantId, tenantContext.TenantId))
                        {
                            throw new InvalidOperationException("Cross-tenant write blocked.");
                        }

                        break;
                }
            }

            if (entry.Entity is AuditableEntity auditable)
            {
                // In-memory mirror of audit.stamp_audit_columns(); EF never sends these columns.
                var actor = tenantContext.IsResolved ? tenantContext.UserId : AuditActors.System;
                if (entry.State == EntityState.Added)
                {
                    auditable.CreatedOn = now;
                    auditable.CreatedBy = actor;
                    auditable.UpdatedOn = now;
                    auditable.UpdatedBy = actor;
                    auditable.IsDeleted = false;
                }
                else if (entry.State == EntityState.Modified)
                {
                    auditable.UpdatedOn = now;
                    auditable.UpdatedBy = actor;
                }
            }
        }
    }
}
