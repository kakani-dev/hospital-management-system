using Hms.SharedKernel.Tenancy;

namespace Hms.Modules.Appointments.Endpoints;

/// <summary>Role sets from SPRINT2-CONTRACT §0 / API §A.2. Writes are checked AT the row's branch (D9).</summary>
internal static class AppointmentRoles
{
    public static readonly string[] RegRead = [HmsRoles.TenantAdmin, HmsRoles.Doctor, HmsRoles.Nurse, HmsRoles.Receptionist, HmsRoles.Billing];
    public static readonly string[] RegWrite = [HmsRoles.TenantAdmin, HmsRoles.Doctor, HmsRoles.Nurse, HmsRoles.Receptionist];
    public static readonly string[] FrontDesk = [HmsRoles.TenantAdmin, HmsRoles.Receptionist, HmsRoles.Nurse];
    public static readonly string[] Admin = [HmsRoles.TenantAdmin];
    public static readonly string[] Doctor = [HmsRoles.Doctor];

    public static bool AnyBranch(ITenantContext tenant, string[] roles) =>
        tenant.IsResolved && tenant.RolesByBranch.Keys.Any(b => tenant.HasRoleAtBranch(b, roles));
}
