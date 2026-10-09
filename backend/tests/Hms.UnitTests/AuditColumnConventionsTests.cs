using Hms.Modules.Identity.Domain;
using Hms.Modules.Identity.Persistence;
using Hms.Modules.Patients.Domain;
using Hms.Modules.Patients.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata;

namespace Hms.UnitTests;

/// <summary>Review M2: EF must never send DB-managed audit columns (and never deleted_at on INSERT).</summary>
public class AuditColumnConventionsTests
{
    private static readonly string[] AuditColumns = ["CreatedAt", "CreatedBy", "UpdatedAt", "UpdatedBy"];

    private static IModel PatientsModel() =>
        new PatientsDbContext(new DbContextOptionsBuilder<PatientsDbContext>().UseNpgsql("Host=unused").UseSnakeCaseNamingConvention().Options, new TenantContext()).Model;

    private static IModel IdentityModel() =>
        new IdentityDbContext(new DbContextOptionsBuilder<IdentityDbContext>().UseNpgsql("Host=unused").UseSnakeCaseNamingConvention().Options).Model;

    public static TheoryData<string> Columns() => new(AuditColumns);

    [Theory]
    [MemberData(nameof(Columns))]
    public void Patient_audit_columns_are_ignored_on_insert_and_update(string column)
    {
        var property = PatientsModel().FindEntityType(typeof(Patient))!.FindProperty(column)!;
        Assert.Equal(PropertySaveBehavior.Ignore, property.GetBeforeSaveBehavior());
        Assert.Equal(PropertySaveBehavior.Ignore, property.GetAfterSaveBehavior());
    }

    [Fact]
    public void Patient_deleted_at_is_never_sent_because_soft_delete_goes_through_the_rpc()
    {
        // Sprint 2 D1: patient.soft_delete_patient / restore_patient own deleted_at (update grant revoked).
        var property = PatientsModel().FindEntityType(typeof(Patient))!.FindProperty(nameof(Patient.DeletedAt))!;
        Assert.Equal(PropertySaveBehavior.Ignore, property.GetBeforeSaveBehavior());
        Assert.Equal(PropertySaveBehavior.Ignore, property.GetAfterSaveBehavior());
    }

    [Theory]
    [InlineData(typeof(Tenant))]
    [InlineData(typeof(Branch))]
    [InlineData(typeof(Membership))]
    public void Identity_audit_columns_are_ignored_too(Type entity)
    {
        var type = IdentityModel().FindEntityType(entity)!;
        foreach (var column in AuditColumns)
        {
            var property = type.FindProperty(column)!;
            Assert.Equal(PropertySaveBehavior.Ignore, property.GetBeforeSaveBehavior());
            Assert.Equal(PropertySaveBehavior.Ignore, property.GetAfterSaveBehavior());
        }
    }

    [Fact]
    public void Business_columns_are_still_saved()
    {
        var type = PatientsModel().FindEntityType(typeof(Patient))!;
        foreach (var column in new[] { nameof(Patient.Mrn), nameof(Patient.FirstName), nameof(Patient.Phone), nameof(Patient.Email), nameof(Patient.TenantId) })
        {
            Assert.Equal(PropertySaveBehavior.Save, type.FindProperty(column)!.GetBeforeSaveBehavior());
        }
    }
}
