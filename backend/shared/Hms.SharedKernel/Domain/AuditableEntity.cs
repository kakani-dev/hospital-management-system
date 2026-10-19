namespace Hms.SharedKernel.Domain;

/// <summary>
/// The five mandatory audit columns (created_on, created_by, updated_on, updated_by, is_deleted).
/// They are owned by PostgreSQL (audit.stamp_audit_columns() trigger + defaults; client column
/// grants are revoked) and are NEVER sent by EF (<see cref="Persistence.AuditColumnConventions"/>).
/// The save interceptor still fills the in-memory values so the tracked entity looks sensible after
/// SaveChanges. is_deleted only changes through the SQL soft-delete / restore functions.
/// </summary>
public abstract class AuditableEntity
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTimeOffset CreatedOn { get; set; }
    public Guid CreatedBy { get; set; }
    public DateTimeOffset UpdatedOn { get; set; }
    public Guid UpdatedBy { get; set; }
    public bool IsDeleted { get; set; }
}
