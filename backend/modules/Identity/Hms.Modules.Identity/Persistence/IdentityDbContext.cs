using Hms.Modules.Identity.Domain;
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
        });

        modelBuilder.Entity<Branch>(e =>
        {
            e.ToTable("branches");
            e.HasIndex(x => new { x.TenantId, x.Code }).IsUnique();
        });

        modelBuilder.Entity<Membership>(e =>
        {
            e.ToTable("memberships");
            e.HasIndex(x => new { x.UserId, x.TenantId });
        });

        modelBuilder.Entity<UserProfile>(e => e.ToTable("user_profiles"));
    }
}
