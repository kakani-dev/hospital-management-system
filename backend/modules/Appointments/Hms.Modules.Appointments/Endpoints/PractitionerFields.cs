using Hms.Modules.Appointments.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Hms.Modules.Appointments.Endpoints;

internal static class PractitionerFields
{
    internal readonly record struct Profile(string? RegistrationNumber, string? CouncilName, string? Qualifications, string? Phone, string? Email);

    internal readonly record struct Parsed(Profile Value, Dictionary<string, string[]> Errors);

    public static Parsed Read(string? registration, string? council, string? qualifications, string? phone, string? email, bool creating)
    {
        var errors = new Dictionary<string, string[]>();
        string? registrationNumber = null;
        if ((creating || registration is not null) && !NmcRegistration.TryNormalize(registration, out registrationNumber))
        {
            errors["registrationNumber"] = ["Use the council registration number, for example KMC/2018/12345."];
        }

        var councilName = OptionalText(council, creating, 120, "councilName", "Council name must be 1-120 characters.", errors);
        var qualificationText = OptionalText(qualifications, creating, 200, "qualifications", "Qualifications must be 1-200 characters.", errors);

        string? phoneNumber = null;
        if ((creating || phone is not null) && !NmcRegistration.TryNormalizePhone(phone, out phoneNumber))
        {
            errors["phone"] = ["Enter a phone number, for example +919800000201."];
        }

        string? emailAddress = null;
        if ((creating || email is not null) && !NmcRegistration.TryNormalizeEmail(email, out emailAddress))
        {
            errors["email"] = ["Enter a valid email address."];
        }

        return new Parsed(new Profile(registrationNumber, councilName, qualificationText, phoneNumber, emailAddress), errors);
    }

    public static async Task<string?> DepartmentErrorAsync(AppointmentsDbContext db, Guid? departmentId, CancellationToken ct)
    {
        if (departmentId is null || departmentId == Guid.Empty)
        {
            return null;
        }

        var department = await db.Departments.AsNoTracking().SingleOrDefaultAsync(d => d.Id == departmentId, ct);
        if (department is null)
        {
            return "Department was not found.";
        }

        return department.IsActive ? null : "That department is inactive.";
    }

    /// <summary>Sequential duplicate. The unique index is what stops two requests at once; a 23505 still rolls the insert back.</summary>
    public static Task<bool> RegistrationTakenAsync(AppointmentsDbContext db, string? registration, Guid? exceptId, CancellationToken ct) =>
        registration is null
            ? Task.FromResult(false)
            : db.Practitioners.AsNoTracking().AnyAsync(p => p.RegistrationNumber == registration && p.Id != exceptId, ct);

    private static string? OptionalText(string? raw, bool creating, int max, string key, string message, Dictionary<string, string[]> errors)
    {
        if (!creating && raw is null)
        {
            return null;
        }

        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        var value = raw.Trim();
        if (value.Length > max)
        {
            errors[key] = [message];
        }

        return value;
    }
}
