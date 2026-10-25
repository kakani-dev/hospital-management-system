namespace Hms.SharedKernel.Tenancy;

/// <summary>Tenant-scoped roles. Must match the CHECK constraint on identity.memberships.role.</summary>
public static class HmsRoles
{
    public const string TenantAdmin = "tenant_admin";
    public const string Doctor = "doctor";
    public const string Nurse = "nurse";
    public const string Receptionist = "receptionist";
    public const string Billing = "billing";
    public const string Pharmacist = "pharmacist";
    public const string LabTechnician = "lab_technician";
    public const string Viewer = "viewer";
    /// <summary>Read-only chartered-accountant access. Cannot bill, collect, discount or refund.</summary>
    public const string Accountant = "accountant";

    public static readonly IReadOnlySet<string> All = new HashSet<string>(StringComparer.Ordinal)
    {
        TenantAdmin, Doctor, Nurse, Receptionist, Billing, Pharmacist, LabTechnician, Viewer, Accountant,
    };
}
