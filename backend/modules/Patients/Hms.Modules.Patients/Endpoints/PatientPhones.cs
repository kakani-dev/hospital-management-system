using Hms.Modules.Patients.Domain;
using Hms.Modules.Patients.Persistence;
using Hms.Modules.Patients.Registry;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Patients.Endpoints;

/// <summary>Phone / WhatsApp input rules shared by create and update (Level 1, patient.patient_phones).</summary>
internal static class PatientPhones
{
    internal const string PhoneError = "Enter a valid phone number, e.g. 98765 43210 or +971 50 123 4567.";
    internal const string WhatsappError = "Enter a valid WhatsApp number, e.g. 98765 43210 or +971 50 123 4567.";
    internal const string WhatsappNeedsPhone = "Enter a phone number, or untick \"Same as phone number\" and enter the WhatsApp number.";

    /// <summary>Blank = no number; otherwise E.164 or a validation error.</summary>
    public static string? NormalizePhone(string? raw, string countryCode, Dictionary<string, string[]> errors)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        var e164 = raw.Length > CreatePatientValidator.PhoneMaxLength ? null : PhoneE164.Normalize(raw, countryCode);
        if (e164 is null && !errors.ContainsKey("phone"))
        {
            errors["phone"] = [PhoneError];
        }

        return e164;
    }

    /// <summary>(sameAsPhone, separate WhatsApp E.164). A WhatsApp number equal to the phone collapses to "same".</summary>
    public static (bool Same, string? Number) ResolveWhatsapp(
        WhatsappInput? input, string? rawPhone, string? phoneE164, string countryCode, Dictionary<string, string[]> errors)
    {
        if (input is null)
        {
            return (false, null);
        }

        if (input.SameAsPhone == true)
        {
            if (phoneE164 is null && string.IsNullOrWhiteSpace(rawPhone))
            {
                errors["whatsapp"] = [WhatsappNeedsPhone];
            }

            return (phoneE164 is not null, null);
        }

        if (string.IsNullOrWhiteSpace(input.Number))
        {
            return (false, null);
        }

        var e164 = input.Number.Length > CreatePatientValidator.PhoneMaxLength ? null : PhoneE164.Normalize(input.Number, countryCode);
        if (e164 is null)
        {
            errors["whatsapp"] = [WhatsappError];
            return (false, null);
        }

        return e164 == phoneE164 ? (true, null) : (false, e164);
    }

    public static Task<List<PatientPhoneNumber>> LoadRowsAsync(PatientsDbContext db, Guid patientId, CancellationToken ct) =>
        db.PatientPhones.AsNoTracking().Where(x => x.PatientId == patientId).ToListAsync(ct);

    public static async Task<IReadOnlyList<PatientPhoneDto>> LoadAsync(PatientsDbContext db, Guid patientId, CancellationToken ct) =>
        PatientPhoneDto.From(await LoadRowsAsync(db, patientId, ct));
}
