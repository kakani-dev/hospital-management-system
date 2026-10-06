using Hms.SharedKernel.Domain;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata;

namespace Hms.SharedKernel.Persistence;

/// <summary>
/// Audit columns are owned by the database (audit.stamp_audit_columns() trigger + column
/// defaults; the client column grants are revoked). EF must never send them, otherwise the
/// INSERT/UPDATE would either be rejected (no column privilege) or let the API forge attribution
/// (review M2).
/// </summary>
public static class AuditColumnConventions
{
    public const string DeletedAt = "DeletedAt";

    private static readonly string[] DbManagedColumns =
    [
        nameof(AuditableEntity.CreatedAt),
        nameof(AuditableEntity.CreatedBy),
        nameof(AuditableEntity.UpdatedAt),
        nameof(AuditableEntity.UpdatedBy),
    ];

    /// <summary>
    /// For every <see cref="AuditableEntity"/>: created_at/created_by/updated_at/updated_by are
    /// ignored on INSERT and UPDATE; deleted_at (when mapped) is ignored on INSERT so no row can be
    /// born soft-deleted, but can still be set by an UPDATE (soft delete). Call at the END of
    /// OnModelCreating.
    /// </summary>
    public static ModelBuilder UseDbManagedAuditColumns(this ModelBuilder modelBuilder)
    {
        foreach (var entityType in modelBuilder.Model.GetEntityTypes())
        {
            if (!typeof(AuditableEntity).IsAssignableFrom(entityType.ClrType))
            {
                continue;
            }

            foreach (var name in DbManagedColumns)
            {
                var property = entityType.FindProperty(name);
                if (property is null)
                {
                    continue;
                }

                property.SetBeforeSaveBehavior(PropertySaveBehavior.Ignore);
                property.SetAfterSaveBehavior(PropertySaveBehavior.Ignore);
            }

            entityType.FindProperty(DeletedAt)?.SetBeforeSaveBehavior(PropertySaveBehavior.Ignore);
        }

        return modelBuilder;
    }
}
