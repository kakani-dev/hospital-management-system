using Hms.Modules.Patients.Domain;

namespace Hms.Modules.Patients.Endpoints;

/// <summary>List/search row. <c>DeletedAt</c> is only ever non-null for admins searching with includeDeleted.</summary>
public sealed record PatientSummaryDto(
    Guid Id, string Mrn, string FirstName, string LastName, DateOnly? DateOfBirth, string Sex, Guid RegisteredBranchId,
    string? Phone, DateTimeOffset? DeletedAt)
{
    public static PatientSummaryDto From(Patient p) =>
        new(p.Id, p.Mrn, p.FirstName, p.LastName, p.DateOfBirth, p.Sex, p.RegisteredBranchId, p.Phone, p.DeletedAt);
}

public sealed record PatientDetailDto(
    Guid Id, string Mrn, string FirstName, string LastName, DateOnly? DateOfBirth, string Sex, Guid RegisteredBranchId,
    string? Phone, DateTimeOffset? DeletedAt, string? Email, DateTimeOffset CreatedOn, DateTimeOffset UpdatedOn)
{
    public static PatientDetailDto From(Patient p) =>
        new(p.Id, p.Mrn, p.FirstName, p.LastName, p.DateOfBirth, p.Sex, p.RegisteredBranchId, p.Phone, p.DeletedAt, p.Email, p.CreatedOn, p.UpdatedOn);
}

/// <summary>201 body of POST /patients: the detail plus advisory duplicate warnings (D3; [] when none).</summary>
public sealed record PatientCreatedDto(
    Guid Id, string Mrn, string FirstName, string LastName, DateOnly? DateOfBirth, string Sex, Guid RegisteredBranchId,
    string? Phone, DateTimeOffset? DeletedAt, string? Email, DateTimeOffset CreatedOn, DateTimeOffset UpdatedOn,
    IReadOnlyList<DuplicateCandidateDto> DuplicateWarnings)
{
    public static PatientCreatedDto From(Patient p, IReadOnlyList<DuplicateCandidateDto> warnings) =>
        new(p.Id, p.Mrn, p.FirstName, p.LastName, p.DateOfBirth, p.Sex, p.RegisteredBranchId, p.Phone, p.DeletedAt, p.Email, p.CreatedOn, p.UpdatedOn, warnings);
}

public sealed record DuplicateCandidateDto(
    Guid Id, string Mrn, string FirstName, string LastName, DateOnly? DateOfBirth, string? Phone, Guid RegisteredBranchId,
    IReadOnlyList<string> MatchReasons);

public sealed record DuplicateCheckResponse(IReadOnlyList<DuplicateCandidateDto> Candidates);

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

/// <summary>
/// Body of POST /api/v1/patients/search. The terms travel in the body (not the URL) so names, MRNs,
/// phones and DOBs never land in proxy/edge access logs (review Minor 5). Filters are AND-ed.
/// </summary>
public sealed record PatientSearchRequest(
    string? Search, int? Page, int? PageSize, string? Phone = null, DateOnly? DateOfBirth = null, bool? IncludeDeleted = null);

public sealed record DuplicateCheckRequest(string? FirstName, string? LastName, DateOnly? DateOfBirth, string? Phone, Guid? ExcludePatientId);

public sealed record DeletePatientRequest(string? Reason);
