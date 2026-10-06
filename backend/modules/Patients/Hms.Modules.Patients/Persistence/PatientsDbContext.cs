using Hms.Modules.Patients.Domain;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;

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

        // Audit columns are DB-managed: never sent on INSERT/UPDATE; deleted_at never sent on INSERT.
        modelBuilder.UseDbManagedAuditColumns();
    }
}
