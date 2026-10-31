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
    public DbSet<Department> Departments => Set<Department>();
    public DbSet<VisitType> VisitTypes => Set<VisitType>();
    public DbSet<VisitTypeOverride> VisitTypeOverrides => Set<VisitTypeOverride>();
    public DbSet<PractitionerBranch> PractitionerBranches => Set<PractitionerBranch>();
    public DbSet<Schedule> Schedules => Set<Schedule>();
    public DbSet<ScheduleOverride> ScheduleOverrides => Set<ScheduleOverride>();
    public DbSet<TenantSchedulingSettings> TenantSchedulingSettings => Set<TenantSchedulingSettings>();
    public DbSet<Appointment> Appointments => Set<Appointment>();
    public DbSet<ReminderSettings> ReminderSettings => Set<ReminderSettings>();
    public DbSet<ReminderOptOut> ReminderOptOuts => Set<ReminderOptOut>();
    public DbSet<AppointmentReminder> AppointmentReminders => Set<AppointmentReminder>();
    public DbSet<QueueEntry> QueueEntries => Set<QueueEntry>();

    private Guid CurrentTenantId => tenantContext.IsResolved ? tenantContext.TenantId : Guid.Empty;

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.HasDefaultSchema(Schema);

        modelBuilder.Entity<Practitioner>(e =>
        {
            e.ToTable("practitioners");
            // soft-deleted practitioners are gone for the API (restore goes through the SQL function)
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId && !x.IsDeleted);
        });

        modelBuilder.Entity<Department>(e =>
        {
            e.ToTable("departments");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId && !x.IsDeleted);
        });

        modelBuilder.Entity<VisitType>(e =>
        {
            e.ToTable("visit_types");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId && !x.IsDeleted);
            ReadOnlyAfterInsert(e.Property(x => x.Code));
        });

        modelBuilder.Entity<VisitTypeOverride>(e =>
        {
            e.ToTable("visit_type_overrides");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId && !x.IsDeleted);
        });

        modelBuilder.Entity<PractitionerBranch>(e =>
        {
            e.ToTable("practitioner_branches");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId && !x.IsDeleted);
        });

        modelBuilder.Entity<Schedule>(e =>
        {
            e.ToTable("schedules");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId && !x.IsDeleted);
            // tenant_id / id are insert-only; the rest is in the update grant.
        });

        modelBuilder.Entity<ScheduleOverride>(e =>
        {
            e.ToTable("schedule_overrides");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId && !x.IsDeleted);
        });

        modelBuilder.Entity<ReminderSettings>(e =>
        {
            e.ToTable("reminder_settings");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId && !x.IsDeleted);
        });
        modelBuilder.Entity<ReminderOptOut>(e =>
        {
            e.ToTable("reminder_opt_outs");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId && !x.IsDeleted);
        });
        modelBuilder.Entity<AppointmentReminder>(e =>
        {
            e.ToTable("appointment_reminders");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId && !x.IsDeleted);
        });

        modelBuilder.Entity<TenantSchedulingSettings>(e =>
        {
            e.ToTable("tenant_settings");
            e.HasQueryFilter(x => x.TenantId == CurrentTenantId && !x.IsDeleted);
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
            ReadOnlyAfterInsert(e.Property(x => x.ParentAppointmentId));
            // Visit type and the fee snapshot are fixed at booking (insert grant only).
            ReadOnlyAfterInsert(e.Property(x => x.VisitTypeId));
            ReadOnlyAfterInsert(e.Property(x => x.ConsultationFeePaise));
            ReadOnlyAfterInsert(e.Property(x => x.GrantedFollowUpDays));
            ReadOnlyAfterInsert(e.Property(x => x.GrantedFollowUpFeePaise));
            ReadOnlyAfterInsert(e.Property(x => x.GrantedFollowUpLimit));
            ReadOnlyAfterInsert(e.Property(x => x.FollowUpEntitlementId));
            ReadOnlyAfterInsert(e.Property(x => x.ConsultationFeeNote));
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
