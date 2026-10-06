namespace Hms.SharedKernel.Domain;

/// <summary>
/// Audit columns. They are owned by PostgreSQL (audit.stamp_audit_columns() trigger + defaults) and
/// are NEVER sent by EF (<see cref="Persistence.AuditColumnConventions"/>). The save interceptor
/// still fills the in-memory values so the tracked entity looks sensible after SaveChanges.
/// </summary>
public abstract class AuditableEntity
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTimeOffset CreatedAt { get; set; }
    public Guid? CreatedBy { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public Guid? UpdatedBy { get; set; }
}
