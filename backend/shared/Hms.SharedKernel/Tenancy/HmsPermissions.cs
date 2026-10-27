namespace Hms.SharedKernel.Tenancy;

/// <summary>
/// Level 1 permission catalog and the role -> permission matrix (docs/adr/0001-role-based-access-control.md).
/// Endpoints check PERMISSIONS, never role strings. Roles come only from server-side membership
/// (ITenantContext, resolved by the tenant middleware); the client never supplies them.
/// Mirrored in the database by identity.role_permissions + identity.has_tenant_permission().
/// </summary>
public static class HmsPermissions
{
    public const string SettingsView = "settings.view";
    public const string SettingsManage = "settings.manage";
    public const string BranchesView = "branches.view";
    public const string BranchesManage = "branches.manage";
    public const string MembersManage = "members.manage";
    public const string PractitionersView = "practitioners.view";
    public const string PractitionersManage = "practitioners.manage";
    public const string PatientsView = "patients.view";
    public const string PatientsCreate = "patients.create";
    public const string PatientsEdit = "patients.edit";
    public const string PatientsDelete = "patients.delete";
    public const string PatientsRestore = "patients.restore";
    public const string AppointmentsView = "appointments.view";
    public const string AppointmentsBook = "appointments.book";
    public const string AppointmentsReschedule = "appointments.reschedule";
    public const string AppointmentsCancel = "appointments.cancel";
    public const string AppointmentsCheckIn = "appointments.check_in";
    public const string AppointmentsNoShow = "appointments.no_show";
    /// <summary>No-show only on appointments of the practitioner linked to the caller (doctor).</summary>
    public const string AppointmentsNoShowOwn = "appointments.no_show_own";
    /// <summary>Book a follow-up of any earlier visit in the hospital, at a branch the caller can access (doctor).</summary>
    public const string AppointmentsBookFollowUpOwn = "appointments.book_followup_own";
    /// <summary>Book outside the practitioner's working hours (explicit override, audited).</summary>
    public const string AppointmentsOverrideHours = "appointments.override_hours";
    public const string QueueView = "queue.view";
    public const string QueueManage = "queue.manage";
    /// <summary>Move the caller's own queue entries to in_consultation / done (doctor).</summary>
    public const string QueueConsultOwn = "queue.consult_own";
    public const string BillingView = "billing.view";
    public const string BillingBill = "billing.bill";
    public const string BillingCollect = "billing.collect";
    public const string BillingDiscountRequest = "billing.discount_request";
    public const string BillingApprove = "billing.approve";
    public const string BillingRefund = "billing.refund";
    /// <summary>Read the earnings dashboard and CA registers. Not granted to reception.</summary>
    public const string BillingEarnings = "billing.earnings";
    public const string BillingCounterReconcile = "billing.counter_reconcile";
    public const string BillingPricelistManage = "billing.pricelist_manage";
    public const string InventoryView = "inventory.view";
    public const string InventoryCatalog = "inventory.catalog";
    public const string InventoryOpening = "inventory.opening";
    public const string InventoryApprove = "inventory.approve";
    /// <summary>See the "Prescriptions to dispense" queue and a prescription's dispense state (#106).</summary>
    public const string PharmacyView = "pharmacy.view";
    /// <summary>Dispense a finalized prescription from a licensed pharmacy store (FEFO stock deduction).</summary>
    public const string PharmacyDispense = "pharmacy.dispense";
    public const string PrivacyView = "privacy.view";
    public const string PrivacyConsent = "privacy.consent";
    public const string PrivacyNotice = "privacy.notice";
    public const string PrivacyRequest = "privacy.request";
    public const string PrivacyFulfil = "privacy.fulfil";
    public const string PrivacyErase = "privacy.erase";
    public const string ClinicalView = "clinical.view";
    public const string ClinicalWrite = "clinical.write";
    /// <summary>Record triage vitals (nurse, doctor, tenant admin). Reading uses <see cref="ClinicalView"/>.</summary>
    public const string ClinicalVitals = "clinical.vitals";

    private static readonly string[] ReadOnlyOps = [SettingsView, BranchesView, PractitionersView];

    public static readonly IReadOnlyDictionary<string, IReadOnlySet<string>> ByRole = new Dictionary<string, IReadOnlySet<string>>(StringComparer.Ordinal)
    {
        [HmsRoles.TenantAdmin] = Set(
            SettingsView, SettingsManage, BranchesView, BranchesManage, MembersManage, PractitionersView, PractitionersManage,
            PatientsView, PatientsCreate, PatientsEdit, PatientsDelete, PatientsRestore,
            AppointmentsView, AppointmentsBook, AppointmentsReschedule, AppointmentsCancel, AppointmentsCheckIn, AppointmentsNoShow,
            AppointmentsOverrideHours, QueueView, QueueManage,
            BillingView, BillingBill, BillingCollect, BillingDiscountRequest, BillingApprove, BillingRefund, BillingEarnings,
            BillingCounterReconcile, BillingPricelistManage,
            InventoryView, InventoryCatalog, InventoryOpening, InventoryApprove, PharmacyView, PharmacyDispense,
            PrivacyView, PrivacyConsent, PrivacyNotice, PrivacyRequest, PrivacyFulfil, PrivacyErase,
            ClinicalView, ClinicalVitals),
        [HmsRoles.Receptionist] = Set([.. ReadOnlyOps,
            PatientsView, PatientsCreate, PatientsEdit, PatientsDelete,
            AppointmentsView, AppointmentsBook, AppointmentsReschedule, AppointmentsCancel, AppointmentsCheckIn, AppointmentsNoShow,
            QueueView, QueueManage,
            BillingView, BillingBill, BillingCollect, BillingDiscountRequest,
            PrivacyView, PrivacyConsent, PrivacyRequest]),
        [HmsRoles.Nurse] = Set([.. ReadOnlyOps, PatientsView, AppointmentsView, AppointmentsBook, AppointmentsCheckIn, AppointmentsNoShow, QueueView, QueueManage, ClinicalView, ClinicalVitals]),
        [HmsRoles.Doctor] = Set([.. ReadOnlyOps, PatientsView, AppointmentsView, AppointmentsBookFollowUpOwn, AppointmentsNoShowOwn, QueueView, QueueConsultOwn, PrivacyView, ClinicalView, ClinicalWrite, ClinicalVitals]),
        [HmsRoles.Billing] = Set([.. ReadOnlyOps, PatientsView, AppointmentsView,
            // read-only queue so the cashier can Collect from a token row; no check-in, advance, cancel or close (queue.manage)
            QueueView,
            BillingView, BillingBill, BillingCollect, BillingDiscountRequest, BillingRefund, BillingEarnings]),
        [HmsRoles.Pharmacist] = Set([.. ReadOnlyOps, InventoryView, PharmacyView, PharmacyDispense]),
        [HmsRoles.LabTechnician] = Set(ReadOnlyOps),
        [HmsRoles.Viewer] = Set(ReadOnlyOps),
        [HmsRoles.Accountant] = Set([.. ReadOnlyOps, BillingEarnings]),
    };

    public static readonly IReadOnlySet<string> All = new HashSet<string>(ByRole.Values.SelectMany(p => p), StringComparer.Ordinal);

    public static IReadOnlySet<string> For(IEnumerable<string> roles) =>
        new HashSet<string>(roles.SelectMany(r => ByRole.TryGetValue(r, out var p) ? p : (IEnumerable<string>)[]), StringComparer.Ordinal);

    private static HashSet<string> Set(params string[] p) => new(p, StringComparer.Ordinal);
}

/// <summary>Permission checks over the server-resolved tenant context (the only way endpoints authorize).</summary>
public static class TenantPermissionExtensions
{
    /// <summary>Tenant-wide: the permission is granted by any membership valid in the current context.</summary>
    public static bool Can(this ITenantContext tenant, string permission) =>
        tenant.IsResolved && HmsPermissions.For(tenant.Roles).Contains(permission);

    /// <summary>Branch-bound: granted by a role held AT <paramref name="branchId"/> (for branch-scoped writes).</summary>
    public static bool CanAtBranch(this ITenantContext tenant, Guid branchId, string permission) =>
        tenant.IsResolved && tenant.RolesByBranch.TryGetValue(branchId, out var roles) && HmsPermissions.For(roles).Contains(permission);

    public static bool CanAtAnyBranch(this ITenantContext tenant, string permission) =>
        tenant.IsResolved && tenant.RolesByBranch.Keys.Any(b => tenant.CanAtBranch(b, permission));

    public static IReadOnlyList<string> EffectivePermissions(this ITenantContext tenant) =>
        tenant.IsResolved ? [.. HmsPermissions.For(tenant.Roles).Order(StringComparer.Ordinal)] : [];
}
