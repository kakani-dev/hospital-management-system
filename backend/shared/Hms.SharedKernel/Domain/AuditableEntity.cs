namespace Hms.SharedKernel.Domain;

/// <summary>
/// Audit columns. In PostgreSQL these are (re)stamped by the audit.stamp_audit_columns() trigger;
/// the API also sets them so non-Postgres providers (tests) behave the same.
/// </summary>
public abstract class AuditableEntity
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTimeOffset CreatedAt { get; set; }
    public Guid? CreatedBy { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public Guid? UpdatedBy { get; set; }
}
