using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Billing.Persistence;

/// <summary>
/// Session and transaction host for the billing schema. Rows are written by SQL functions;
/// this context does not map entities.
/// </summary>
public sealed class BillingDbContext(DbContextOptions<BillingDbContext> options) : DbContext(options)
{
    public const string Schema = "billing";

    protected override void OnModelCreating(ModelBuilder modelBuilder) =>
        modelBuilder.HasDefaultSchema(Schema);
}
