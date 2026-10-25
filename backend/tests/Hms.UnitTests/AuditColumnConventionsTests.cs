using Hms.Modules.Appointments.Domain;
using Hms.Modules.Appointments.Persistence;
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
    // The five mandatory audit columns (identity/patient/appointment tables; supabase/tests/17_audit_columns_test.sql is the DB-side guard).
    private static readonly string[] AuditColumns = ["CreatedOn", "CreatedBy", "UpdatedOn", "UpdatedBy", "IsDeleted"];

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
    public void Zone_columns_are_never_updated_by_ef()
    {
        // DB re-review R5: zone changes go through identity.change_time_zone_v1 (no client UPDATE grant).
        var tenantZone = IdentityModel().FindEntityType(typeof(Tenant))!.FindProperty(nameof(Tenant.TimeZone))!;
        Assert.Equal(PropertySaveBehavior.Ignore, tenantZone.GetAfterSaveBehavior());
        var branchZone = IdentityModel().FindEntityType(typeof(Branch))!.FindProperty(nameof(Branch.Timezone))!;
        Assert.Equal(PropertySaveBehavior.Ignore, branchZone.GetAfterSaveBehavior());
        // code review MAJ-1: the override has its own column; branches.timezone is the DB-kept mirror
        Assert.Equal("timezone_override", branchZone.GetColumnName());
    }

    [Fact]
    public void Setup_columns_are_never_written_by_ef()
    {
        var tenant = IdentityModel().FindEntityType(typeof(Tenant))!;
        foreach (var name in new[] { nameof(Tenant.SetupStep), nameof(Tenant.SetupCompletedOn) })
        {
            var property = tenant.FindProperty(name)!;
            Assert.Equal(PropertySaveBehavior.Ignore, property.GetBeforeSaveBehavior());
            Assert.Equal(PropertySaveBehavior.Ignore, property.GetAfterSaveBehavior());
        }
    }

    private static IModel AppointmentsModel() =>
        new AppointmentsDbContext(new DbContextOptionsBuilder<AppointmentsDbContext>().UseNpgsql("Host=unused").UseSnakeCaseNamingConvention().Options, new TenantContext()).Model;

    [Theory]
    [InlineData(typeof(Practitioner))]
    [InlineData(typeof(PractitionerBranch))]
    [InlineData(typeof(Schedule))]
    [InlineData(typeof(ScheduleOverride))]
    [InlineData(typeof(TenantSchedulingSettings))]
    [InlineData(typeof(Appointment))]
    [InlineData(typeof(QueueEntry))]
    public void Appointment_audit_columns_are_ignored_too(Type entity)
    {
        var type = AppointmentsModel().FindEntityType(entity)!;
        foreach (var column in AuditColumns)
        {
            var property = type.FindProperty(column)!;
            Assert.Equal(PropertySaveBehavior.Ignore, property.GetBeforeSaveBehavior());
            Assert.Equal(PropertySaveBehavior.Ignore, property.GetAfterSaveBehavior());
        }
    }

    [Fact]
    public void Every_auditable_entity_maps_the_five_snake_case_columns()
    {
        string[] expected = ["created_on", "created_by", "updated_on", "updated_by", "is_deleted"];
        foreach (var model in new[] { PatientsModel(), IdentityModel(), AppointmentsModel() })
        {
            foreach (var type in model.GetEntityTypes().Where(t => typeof(Hms.SharedKernel.Domain.AuditableEntity).IsAssignableFrom(t.ClrType)))
            {
                var columns = type.GetProperties().Select(p => p.GetColumnName()).ToHashSet(StringComparer.Ordinal);
                foreach (var column in expected)
                {
                    Assert.True(columns.Contains(column), $"{type.ClrType.Name} does not map {column}");
                }

                Assert.DoesNotContain("created_at", columns);
                Assert.DoesNotContain("updated_at", columns);
            }
        }
    }

    [Fact]
    public void Business_columns_are_still_saved()
    {
        var type = PatientsModel().FindEntityType(typeof(Patient))!;
        foreach (var column in new[] { nameof(Patient.FirstName), nameof(Patient.Email), nameof(Patient.TenantId) })
        {
            Assert.Equal(PropertySaveBehavior.Save, type.FindProperty(column)!.GetBeforeSaveBehavior());
        }
    }

    [Fact]
    public void Mrn_and_the_deprecated_phone_are_never_written_by_ef()
    {
        // MRN: generated by patient.assign_mrn() and read back; phone: mirror written by set_patient_phones.
        var type = PatientsModel().FindEntityType(typeof(Patient))!;
        foreach (var column in new[] { nameof(Patient.Mrn), nameof(Patient.Phone) })
        {
            Assert.Equal(PropertySaveBehavior.Ignore, type.FindProperty(column)!.GetBeforeSaveBehavior());
            Assert.Equal(PropertySaveBehavior.Ignore, type.FindProperty(column)!.GetAfterSaveBehavior());
        }

        Assert.Equal(Microsoft.EntityFrameworkCore.Metadata.ValueGenerated.OnAdd, type.FindProperty(nameof(Patient.Mrn))!.ValueGenerated);
    }
}
