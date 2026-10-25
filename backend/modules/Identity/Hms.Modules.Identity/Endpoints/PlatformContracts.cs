namespace Hms.Modules.Identity.Endpoints;

/// <summary>Public "Register your hospital" form (POST /api/v1/public/hospital-signups, anonymous).</summary>
/// <param name="Website">Honeypot: humans never see the field; a non-empty value is silently dropped.</param>
public sealed record HospitalSignupRequest(
    string? HospitalName, string? TimeZone, string? ContactName, string? ContactEmail, string? Phone, string? City, string? Website = null);

/// <summary>Same body for every accepted outcome (stored, pending duplicate, honeypot), so the form cannot probe who already applied. An email that already belongs to a hospital is a 409 with a fixed message and no tenant details.</summary>
public sealed record HospitalSignupAcceptedDto(string Message)
{
    public const string Text = "Thank you. Your request was received; our team will review it and email the contact person.";

    public static readonly HospitalSignupAcceptedDto Instance = new(Text);
}

public sealed record HospitalRequestDto(
    Guid Id, string HospitalName, string TimeZone, string ContactName, string ContactEmail, string Phone, string City,
    string Status, string? DecisionReason, DateTimeOffset? DecidedOn, Guid? TenantId, string? TenantCode, DateTimeOffset CreatedOn,
    bool PossibleDuplicate, IReadOnlyList<string> MatchedHospitals);

/// <param name="AcknowledgeDuplicate">Required when the request currently matches another hospital. Ignored otherwise.</param>
public sealed record ApproveHospitalRequest(string? TenantCode, bool AcknowledgeDuplicate = false);

public sealed record RejectHospitalRequest(string? Reason);

/// <summary>One-time invite link (the token is shown once; only its hash is stored).</summary>
public sealed record InviteLinkIssuedDto(Guid Id, string Token, string Path, DateTimeOffset ExpiresOn);

public sealed record HospitalApprovedDto(Guid TenantId, InviteLinkIssuedDto Invite);

public sealed record PlatformTenantDto(
    Guid Id, string Code, string Name, string Status, string TimeZone, DateTimeOffset CreatedOn,
    long BranchCount, long UserCount, long PendingInvites, string? StatusReason);

public sealed record TenantStatusChangeDto(string FromStatus, string ToStatus, string Reason, DateTimeOffset ChangedOn, string? ChangedBy);

public sealed record PlatformTenantDetailDto(PlatformTenantDto Tenant, IReadOnlyList<TenantStatusChangeDto> History);

public sealed record PlatformCreateTenantRequest(string? Code, string? Name, string? TimeZone, string? AdminEmail);

public sealed record TenantStatusRequest(string? Reason);

public sealed record AdminInviteRequest(string? Email);

public sealed record CreateInviteLinkRequest(string? Email, string? Role, Guid? BranchId);

public sealed record InviteLinkDto(Guid Id, string Email, string Role, Guid? BranchId, string Status, DateTimeOffset ExpiresOn, DateTimeOffset CreatedOn, DateTimeOffset? ClaimedOn);

public sealed record InvitePreviewDto(string TenantName, string Role, string? BranchName, string EmailHint, DateTimeOffset ExpiresOn);

public sealed record ClaimInviteRequest(string? Token);

public sealed record ClaimedInviteDto(Guid TenantId, string TenantName, string Role, Guid? BranchId);
