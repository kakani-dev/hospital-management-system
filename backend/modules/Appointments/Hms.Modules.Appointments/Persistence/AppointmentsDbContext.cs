using Hms.Modules.Appointments.Domain;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Hms.Modules.Appointments.Persistence;

/// <summary>
/// Appointment service schema ("appointment"). Global query filters pin every query to the
/// RESOLVED tenant (fail closed when unresolved). SQL in supabase/migrations is the source of truth.
/// Only columns in the DB column grants are ever sent (SPRINT2-CONTRACT §2.6).
/// </summary>
public sealed class AppointmentsDbContext(DbContextOptions<AppointmentsDbContext> options, ITenantContext tenantContext) : DbContext(options)
{
    public const string Schema = "appointment";

    public DbSet<Practitioner> Practitioners => Set<Practitioner>();
    public DbSet<Schedule> Schedules => Set<Schedule>();
    public DbSet<Appointment> Appointments => Set<Appointment>();
    public DbSet<QueueEntry> QueueEntries => Set<QueueEntry>();

    /// <summary>Read-only view of patient.patients (embedding only; never Add/Update it).</summary>
    public IQueryable<PatientRef> PatientRefs => Set<PatientRef>().AsNoTracking();

    private Guid CurrentTenantId => tenantContext.IsResolved ? tenantContext.TenantId : Guid.Empty;

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.HasDefaultSchema(Schema);

        modelBuilder.Entity<Practitioner>(e =>
        {
            e.ToTable("practitioners");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId);
        });

        modelBuilder.Entity<Schedule>(e =>
        {
            e.ToTable("schedules");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId);
            // tenant_id / id are insert-only; the rest is in the update grant.
        });

        modelBuilder.Entity<Appointment>(e =>
        {
            e.ToTable("appointments");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId);
            // status: DB default on INSERT (not in the insert grant), updatable afterwards.
            e.Property(x => x.Status).Metadata.SetBeforeSaveBehavior(PropertySaveBehavior.Ignore);
            // cancel_reason: update-only (not in the insert grant); a new booking never has one.
            e.Property(x => x.CancelReason).Metadata.SetBeforeSaveBehavior(PropertySaveBehavior.Ignore);
            // never updatable (no update grant): the trigger rejects identity changes once not booked anyway
            ReadOnlyAfterInsert(e.Property(x => x.PatientId));
            ReadOnlyAfterInsert(e.Property(x => x.BranchId));
            // lifecycle timestamps: owned by appointment.enforce_appointment_transition()
            DbOwned(e.Property(x => x.CheckedInAt));
            DbOwned(e.Property(x => x.StartedAt));
            DbOwned(e.Property(x => x.CompletedAt));
            DbOwned(e.Property(x => x.CancelledAt));
        });

        modelBuilder.Entity<QueueEntry>(e =>
        {
            e.ToTable("queue_entries");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId);
        });

        modelBuilder.Entity<PatientRef>(e =>
        {
            e.ToTable("patients", "patient", t => t.ExcludeFromMigrations());
            // Same visibility as GET /patients/{id}: this tenant, not soft-deleted (RLS adds the role check).
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId && x.DeletedAt == null);
            foreach (var property in e.Metadata.GetProperties().Where(p => !p.IsKey()))
            {
                property.SetBeforeSaveBehavior(PropertySaveBehavior.Ignore);
                property.SetAfterSaveBehavior(PropertySaveBehavior.Ignore);
            }
        });

        modelBuilder.UseDbManagedAuditColumns();
    }

    private static void DbOwned<T>(PropertyBuilder<T> property)
    {
        property.Metadata.SetBeforeSaveBehavior(PropertySaveBehavior.Ignore);
        property.Metadata.SetAfterSaveBehavior(PropertySaveBehavior.Ignore);
    }

    private static void ReadOnlyAfterInsert<T>(PropertyBuilder<T> property) =>
        property.Metadata.SetAfterSaveBehavior(PropertySaveBehavior.Ignore);
}
