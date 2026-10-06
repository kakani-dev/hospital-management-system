using Hms.SharedKernel.Domain;
using Hms.SharedKernel.Tenancy;

namespace Hms.Modules.Patients.Domain;

public sealed class Patient : AuditableEntity, ITenantOwned
{
    public Guid TenantId { get; set; }
    public Guid RegisteredBranchId { get; set; }
    public required string Mrn { get; set; }
    public required string FirstName { get; set; }
    public required string LastName { get; set; }
    public DateOnly? DateOfBirth { get; set; }
    public string Sex { get; set; } = PatientSex.Unknown;
    public string? Phone { get; set; }
    public string? Email { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
}

public static class PatientSex
{
    public const string Female = "female";
    public const string Male = "male";
    public const string Other = "other";
    public const string Unknown = "unknown";

    public static readonly IReadOnlySet<string> All = new HashSet<string>(StringComparer.Ordinal) { Female, Male, Other, Unknown };
}
