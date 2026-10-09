using Hms.Modules.Patients.Domain;
using Hms.Modules.Patients.Registry;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata;

namespace Hms.Modules.Patients.Persistence;

/// <summary>
/// Patient service schema ("patient"). Every query is filtered to the RESOLVED tenant via a
/// global query filter; with no resolved tenant, the filter matches nothing (fail closed).
/// SQL in supabase/migrations is the source of truth for the schema.
/// </summary>
public sealed class PatientsDbContext(DbContextOptions<PatientsDbContext> options, ITenantContext tenantContext) : DbContext(options)
{
    public const string Schema = "patient";

    public DbSet<Patient> Patients => Set<Patient>();

    /// <summary>
    /// Mapped to <c>patient.normalize_phone(text)</c> in PostgreSQL (so the expression index is used);
    /// evaluated in .NET by non-relational providers (unit tests).
    /// </summary>
    public static string? NormalizePhone(string? phone) => PatientPhone.Normalize(phone);

    // Evaluated per query (EF parameterizes DbContext instance members in query filters).
    private Guid CurrentTenantId => tenantContext.IsResolved ? tenantContext.TenantId : Guid.Empty;

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.HasDefaultSchema(Schema);

        modelBuilder.Entity<Patient>(e =>
        {
            e.ToTable("patients");
            e.Property(x => x.Mrn).HasMaxLength(32);
            e.HasIndex(x => new { x.TenantId, x.Mrn }).IsUnique();
            e.HasQueryFilter(p => p.TenantId == CurrentTenantId && p.DeletedAt == null);
        });

        modelBuilder.HasDbFunction(typeof(PatientsDbContext).GetMethod(nameof(NormalizePhone), [typeof(string)])!)
            .HasSchema(Schema).HasName("normalize_phone");

        // Audit columns are DB-managed: never sent on INSERT/UPDATE; deleted_at never sent on INSERT.
        modelBuilder.UseDbManagedAuditColumns();

        // Sprint 2 (D1): soft delete / restore happen ONLY through patient.soft_delete_patient /
        // restore_patient (the update(deleted_at) grant is revoked), so EF never sends deleted_at at all.
        modelBuilder.Entity<Patient>().Property(x => x.DeletedAt).Metadata.SetAfterSaveBehavior(PropertySaveBehavior.Ignore);
    }
}
