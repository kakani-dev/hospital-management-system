using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Inventory.Persistence;

/// <summary>
/// Session and transaction host for the inventory schema. Rows are written by SQL functions;
/// this context does not map entities.
/// </summary>
public sealed class InventoryDbContext(DbContextOptions<InventoryDbContext> options) : DbContext(options)
{
    public const string Schema = "inventory";

    protected override void OnModelCreating(ModelBuilder modelBuilder) =>
        modelBuilder.HasDefaultSchema(Schema);
}
