using Hms.Modules.Identity.Domain;
using Hms.SharedKernel.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Identity.Persistence;

/// <summary>
/// Maps the Identity &amp; Tenant service schema ("identity"). Schema is owned by
/// supabase/migrations (SQL is the source of truth); EF migrations are NOT used.
/// Not tenant-filtered: it is used to look up memberships BEFORE a tenant is resolved.
/// Only the Identity module may use it.
/// </summary>
public sealed class IdentityDbContext(DbContextOptions<IdentityDbContext> options) : DbContext(options)
{
    public const string Schema = "identity";

    public DbSet<Tenant> Tenants => Set<Tenant>();
    public DbSet<Branch> Branches => Set<Branch>();
    public DbSet<Membership> Memberships => Set<Membership>();
    public DbSet<UserProfile> UserProfiles => Set<UserProfile>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.HasDefaultSchema(Schema);

        modelBuilder.Entity<Tenant>(e =>
        {
            e.ToTable("tenants");
            e.HasIndex(x => x.Code).IsUnique();
            e.HasQueryFilter(x => !x.IsDeleted);
            // Zone changes go through identity.change_time_zone_v1 (future-bookings confirmation,
            // DB re-review R5); clients have no UPDATE grant on the column, so EF never sends it.
            e.Property(x => x.TimeZone).Metadata.SetAfterSaveBehavior(Microsoft.EntityFrameworkCore.Metadata.PropertySaveBehavior.Ignore);
        });

        modelBuilder.Entity<Branch>(e =>
        {
            e.ToTable("branches");
            e.HasIndex(x => new { x.TenantId, x.Code }).IsUnique();
            // soft-deleted branches are invisible unless a query opts out (admin includeDeleted)
            e.HasQueryFilter(x => !x.IsDeleted);
            // INSERT may carry an override; UPDATEs go through identity.change_time_zone_v1 (R5).
            e.Property(x => x.Timezone).HasColumnName("timezone_override");
            e.Property(x => x.Timezone).Metadata.SetAfterSaveBehavior(Microsoft.EntityFrameworkCore.Metadata.PropertySaveBehavior.Ignore);
        });

        modelBuilder.Entity<Membership>(e =>
        {
            e.ToTable("memberships");
            e.HasIndex(x => new { x.UserId, x.TenantId });
            // a soft-deleted membership grants nothing (the RLS helpers agree)
            e.HasQueryFilter(x => !x.IsDeleted);
        });

        modelBuilder.Entity<UserProfile>(e => e.ToTable("user_profiles"));

        // Audit columns are DB-managed (trigger): EF never sends them.
        modelBuilder.UseDbManagedAuditColumns();
    }
}
