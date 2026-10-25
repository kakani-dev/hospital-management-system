using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Privacy.Persistence;

/// <summary>
/// Session and transaction host for the privacy schema. Rows are written by SQL functions;
/// this context does not map entities.
/// </summary>
public sealed class PrivacyDbContext(DbContextOptions<PrivacyDbContext> options) : DbContext(options)
{
    public const string Schema = "privacy";

    protected override void OnModelCreating(ModelBuilder modelBuilder) =>
        modelBuilder.HasDefaultSchema(Schema);
}
