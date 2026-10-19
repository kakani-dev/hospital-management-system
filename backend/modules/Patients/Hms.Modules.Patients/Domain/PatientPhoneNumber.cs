using Hms.SharedKernel.Domain;
using Hms.SharedKernel.Tenancy;

namespace Hms.Modules.Patients.Domain;

/// <summary>
/// patient.patient_phones (Level 1): one row per (patient, E.164 number). The same number used as
/// phone AND WhatsApp is ONE row with both flags. Read-only for EF: every write goes through
/// <c>patient.set_patient_phones</c> (see IPatientRegistryFunctions.SetPhonesAsync).
/// </summary>
public sealed class PatientPhoneNumber : AuditableEntity, ITenantOwned
{
    public Guid TenantId { get; set; }
    public Guid PatientId { get; set; }
    public required string PhoneE164 { get; set; }
    public bool IsPrimary { get; set; }
    public bool IsWhatsapp { get; set; }
}
