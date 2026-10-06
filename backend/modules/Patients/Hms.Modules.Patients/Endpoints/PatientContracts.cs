using Hms.Modules.Patients.Domain;

namespace Hms.Modules.Patients.Endpoints;

public sealed record PatientSummaryDto(
    Guid Id, string Mrn, string FirstName, string LastName, DateOnly? DateOfBirth, string Sex, Guid RegisteredBranchId)
{
    public static PatientSummaryDto From(Patient p) =>
        new(p.Id, p.Mrn, p.FirstName, p.LastName, p.DateOfBirth, p.Sex, p.RegisteredBranchId);
}

/// <summary>
/// NOTE: there is intentionally no TenantId property. The tenant always comes from the
/// server-resolved tenant context; any "tenantId" a client sends in JSON is ignored.
/// </summary>
public sealed record CreatePatientRequest(
    string? Mrn,
    string? FirstName,
    string? LastName,
    DateOnly? DateOfBirth,
    string? Sex,
    Guid RegisteredBranchId,
    string? Phone,
    string? Email);
