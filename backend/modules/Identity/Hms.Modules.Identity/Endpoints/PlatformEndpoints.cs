using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.RateLimiting;
using Hms.Modules.Identity.Persistence;
using Hms.Platform.Http;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Hms.Modules.Identity.Endpoints;

/// <summary>
/// Platform console (operators in identity.platform_admins) and the public hospital registration.
/// Mapped by the identity service only (code review MIN-5).
/// <list type="bullet">
/// <item><c>/api/v1/platform/**</c>: authenticated, NO tenant needed, and identity.is_platform_admin()
/// server-side (403 otherwise; every SQL function re-checks). Platform admins get no tenant access:
/// these endpoints return tenant metadata and counts only.</item>
/// <item><c>/api/v1/public/**</c>: anonymous; rate limited per client address (<see cref="PublicPolicy"/>)
/// plus the per-source / global caps in identity.submit_tenant_signup.</item>
/// </list>
/// </summary>
public static partial class PlatformEndpoints
{
    public const string PublicPolicy = "hms-public-forms";

    /// <summary>Registers the stricter limiter for the public forms (call from the identity service).</summary>
    public static IServiceCollection AddPlatformEndpoints(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<RateLimiterOptions>(o => o.AddPolicy(PublicPolicy, ctx => RateLimitPartition.GetFixedWindowLimiter(
            ctx.Connection.RemoteIpAddress?.ToString() ?? "anonymous",
            _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = configuration.GetValue("RateLimiting:PublicFormsPerHour", 10),
                Window = TimeSpan.FromHours(1),
                QueueLimit = 0,
            })));
        return services;
    }

    public static RouteGroupBuilder MapPlatformEndpoints(this RouteGroupBuilder api)
    {
        var pub = api.MapGroup("/public").WithTags("Public").AllowAnonymous().WithDbTransaction<IdentityDbContext>();
        pub.MapPost("/hospital-signups", SubmitSignupAsync).WithName("SubmitHospitalSignup").RequireRateLimiting(PublicPolicy)
            .WithSummary("Register your hospital: stores a PENDING request only (no tenant, no access). 202 when received or already pending; 409 when the email already belongs to a hospital.");
        pub.MapGet("/invites/{token}", PreviewInviteAsync).WithName("PreviewInvite").RequireRateLimiting(PublicPolicy)
            .WithSummary("Hospital, role and masked email of a pending invite link; 404 if unknown, used or expired.");
        pub.MapPost("/invites/{token}/sign-in-code", RequestInviteSignInCodeAsync).WithName("RequestInviteSignInCode").RequireRateLimiting(PublicPolicy)
            .WithSummary("Email a one-time sign-in code for this invite. 202 with an expiry; 404 unknown; 429 too many codes.");
        pub.MapPost("/invites/{token}/sign-in", ExchangeInviteSignInCodeAsync).WithName("ExchangeInviteSignInCode").RequireRateLimiting(PublicPolicy)
            .WithSummary("Check the emailed code and return a GoTrue magic-link token hash. The invitee then chooses their own password.");

        var platform = api.MapGroup("/platform").WithTags("Platform").RequireAuthorization().WithDbTransaction<IdentityDbContext>();
        platform.AddEndpointFilter(async (context, next) =>
        {
            var db = context.HttpContext.RequestServices.GetRequiredService<IdentityDbContext>();
            var isAdmin = await RawSql.ScalarAsync(db, "select identity.is_platform_admin()", context.HttpContext.RequestAborted) is true;
            return isAdmin ? await next(context) : HmsProblems.Forbidden("Only platform operators can use the platform console.");
        });
        platform.MapGet("/hospital-requests", ListRequestsAsync).WithName("ListHospitalRequests");
        platform.MapPost("/hospital-requests/{id:guid}/approve", ApproveAsync).WithName("ApproveHospitalRequest")
            .WithSummary("identity.create_tenant (requested zone) + first-admin invite link. 409 if already decided, or if a possible duplicate was not confirmed.");
        platform.MapPost("/hospital-requests/{id:guid}/reject", RejectAsync).WithName("RejectHospitalRequest");
        platform.MapGet("/tenants", ListTenantsAsync).WithName("PlatformListTenants");
        platform.MapGet("/tenants/{id:guid}", GetTenantAsync).WithName("PlatformGetTenant");
        platform.MapPost("/tenants", CreateTenantAsync).WithName("PlatformCreateTenant");
        platform.MapPost("/tenants/{id:guid}/suspend", (Guid id, TenantStatusRequest r, IdentityDbContext db, CancellationToken ct) => SetStatusAsync(id, "suspended", r, db, ct))
            .WithName("PlatformSuspendTenant");
        platform.MapPost("/tenants/{id:guid}/reactivate", (Guid id, TenantStatusRequest r, IdentityDbContext db, CancellationToken ct) => SetStatusAsync(id, "active", r, db, ct))
            .WithName("PlatformReactivateTenant");
        platform.MapPost("/tenants/{id:guid}/admin-invite", ReissueAdminInviteAsync).WithName("PlatformReissueAdminInvite");
        return api;
    }

    internal static InviteLinkIssuedDto Issued(Guid id, string token, DateTimeOffset expiresOn) => new(id, token, $"/invite/{token}", expiresOn);

    // ------------------------------------------------------------------ public ----
    private static async Task<Results<Accepted<HospitalSignupAcceptedDto>, ValidationProblem, ProblemHttpResult>> SubmitSignupAsync(
        HospitalSignupRequest request, IdentityDbContext db, HttpContext http, IConfiguration configuration, CancellationToken ct)
    {
        var errors = Validate(request);
        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        if (!string.IsNullOrEmpty(request.Website))
        {
            return TypedResults.Accepted((string?)null, HospitalSignupAcceptedDto.Instance); // honeypot: drop silently
        }

        try
        {
            await RawSql.ScalarAsync(
                db,
                "select identity.submit_tenant_signup(@name, @zone, @contact, @email, @phone, @city, @source)",
                ct,
                ("name", request.HospitalName!.Trim()),
                ("zone", request.TimeZone!.Trim()),
                ("contact", request.ContactName!.Trim()),
                ("email", request.ContactEmail!.Trim()),
                ("phone", request.Phone!.Trim()),
                ("city", request.City!.Trim()),
                ("source", SourceHash(http, configuration)));
        }
        catch (Exception ex) when (HmsProblems.FindDbError(ex)?.SqlState == "54000")
        {
            return TypedResults.Problem(title: "Too many requests", detail: "Too many registrations were sent. Try again tomorrow or contact us.",
                statusCode: StatusCodes.Status429TooManyRequests, extensions: new Dictionary<string, object?> { ["code"] = "rate_limited" });
        }
        catch (Exception ex) when (IsDbSignal(ex, "P0001", "email_already_registered"))
        {
            // Fixed copy. The database token carries no hospital name, code, or id.
            return TypedResults.Problem(
                title: "Already registered",
                detail: EmailRegisteredDetail,
                statusCode: StatusCodes.Status409Conflict,
                extensions: new Dictionary<string, object?> { ["code"] = "email_registered" });
        }
        catch (Exception ex) when (HmsProblems.FindDbError(ex)?.SqlState == HmsProblems.SqlStates.UniqueViolation)
        {
            // Two pending inserts for one email raced past the check; the unique index kept a single row.
            return TypedResults.Accepted((string?)null, HospitalSignupAcceptedDto.Instance);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }

        return TypedResults.Accepted((string?)null, HospitalSignupAcceptedDto.Instance);
    }

    /// <summary>Salted SHA-256 of the client address (the raw IP is never stored).</summary>
    private static string SourceHash(HttpContext http, IConfiguration configuration)
    {
        var salt = configuration["Onboarding:SourceHashSalt"] ?? "hms-local-onboarding-salt";
        var ip = http.Connection.RemoteIpAddress?.ToString() ?? "unknown";
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{salt}|{ip}")));
    }

    private static async Task<Results<Ok<InvitePreviewDto>, NotFound>> PreviewInviteAsync(string token, IdentityDbContext db, CancellationToken ct)
    {
        if (!TokenPattern().IsMatch(token))
        {
            return TypedResults.NotFound();
        }

        var rows = await RawSql.QueryAsync(
            db,
            "select tenant_name, role, branch_name, email_hint, expires_on from identity.preview_invite_link(@token)",
            r => new InvitePreviewDto(r.GetString(0), r.GetString(1), r.IsDBNull(2) ? null : r.GetString(2), r.GetString(3), r.GetFieldValue<DateTimeOffset>(4)),
            ct,
            ("token", token));
        return rows.Count == 1 ? TypedResults.Ok(rows[0]) : TypedResults.NotFound();
    }

    // ---------------------------------------------------------- hospital requests ----
    private static async Task<Results<Ok<List<HospitalRequestDto>>, ValidationProblem>> ListRequestsAsync(string? status, IdentityDbContext db, CancellationToken ct)
    {
        if (status is not null and not ("pending" or "approved" or "rejected"))
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["status"] = ["Status must be pending, approved or rejected."] });
        }

        var rows = await RawSql.QueryAsync(
            db,
            "select id, hospital_name, time_zone, contact_name, contact_email, phone, city, status, decision_reason, decided_on, tenant_id, tenant_code, created_on, possible_duplicate, matched_hospitals from identity.platform_list_signups(@status)",
            r => new HospitalRequestDto(
                r.GetGuid(0), r.GetString(1), r.GetString(2), r.GetString(3), r.GetString(4), r.GetString(5), r.GetString(6), r.GetString(7),
                r.IsDBNull(8) ? null : r.GetString(8), r.IsDBNull(9) ? null : r.GetFieldValue<DateTimeOffset>(9),
                r.IsDBNull(10) ? null : r.GetGuid(10), r.IsDBNull(11) ? null : r.GetString(11), r.GetFieldValue<DateTimeOffset>(12),
                r.GetBoolean(13), r.IsDBNull(14) ? [] : r.GetFieldValue<string[]>(14)),
            ct,
            ("status", status));
        return TypedResults.Ok(rows);
    }

    private static async Task<Results<Ok<HospitalApprovedDto>, ValidationProblem, ProblemHttpResult>> ApproveAsync(
        Guid id, ApproveHospitalRequest request, IdentityDbContext db, CancellationToken ct)
    {
        if (request.TenantCode is null || !CodePattern().IsMatch(request.TenantCode))
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["tenantCode"] = [CodeRule] });
        }

        try
        {
            var rows = await RawSql.QueryAsync(
                db,
                "select tenant_id, invite_link_id, token, expires_on from identity.platform_approve_signup(@id, @code, @confirm)",
                r => new HospitalApprovedDto(r.GetGuid(0), Issued(r.GetGuid(1), r.GetString(2), r.GetFieldValue<DateTimeOffset>(3))),
                ct,
                ("id", id),
                ("code", request.TenantCode),
                ("confirm", request.AcknowledgeDuplicate));
            return TypedResults.Ok(rows[0]);
        }
        catch (Exception ex) when (IsDbSignal(ex, "P0001", "possible_duplicate"))
        {
            return TypedResults.Problem(
                title: "Possible duplicate",
                detail: PossibleDuplicateDetail,
                statusCode: StatusCodes.Status409Conflict,
                extensions: new Dictionary<string, object?> { ["code"] = "possible_duplicate" });
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex, uniqueDetail: "A hospital with this code already exists. Choose another code.") is { } problem)
        {
            return problem;
        }
    }

    private static async Task<Results<NoContent, ValidationProblem, ProblemHttpResult>> RejectAsync(
        Guid id, RejectHospitalRequest request, IdentityDbContext db, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Reason) || request.Reason.Trim().Length is < 3 or > 500)
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["reason"] = [ReasonRule] });
        }

        try
        {
            await RawSql.ScalarAsync(db, "select identity.platform_reject_signup(@id, @reason)", ct, ("id", id), ("reason", request.Reason));
            return TypedResults.NoContent();
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    // ------------------------------------------------------------------ tenants ----
    private const string TenantColumns = "id, code, name, status, time_zone, created_on, branch_count, user_count, pending_invites, status_reason";

    private static PlatformTenantDto ReadTenant(System.Data.Common.DbDataReader r) => new(
        r.GetGuid(0), r.GetString(1), r.GetString(2), r.GetString(3), r.GetString(4), r.GetFieldValue<DateTimeOffset>(5),
        r.GetInt64(6), r.GetInt64(7), r.GetInt64(8), r.IsDBNull(9) ? null : r.GetString(9));

    private static async Task<Results<Ok<List<PlatformTenantDto>>, ValidationProblem>> ListTenantsAsync(
        string? search, string? status, IdentityDbContext db, CancellationToken ct)
    {
        if (status is not null and not ("active" or "suspended" or "archived"))
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["status"] = ["Status must be active, suspended or archived."] });
        }

        var rows = await RawSql.QueryAsync(db, $"select {TenantColumns} from identity.platform_list_tenants(@search, @status)", ReadTenant, ct,
            ("search", search?.Trim()), ("status", status));
        return TypedResults.Ok(rows);
    }

    private static async Task<Results<Ok<PlatformTenantDetailDto>, NotFound>> GetTenantAsync(Guid id, IdentityDbContext db, CancellationToken ct)
    {
        var rows = (await RawSql.QueryAsync(db, $"select {TenantColumns} from identity.platform_list_tenants(null, null)", ReadTenant, ct))
            .Where(t => t.Id == id).ToList();
        if (rows.Count == 0)
        {
            return TypedResults.NotFound();
        }

        var history = await RawSql.QueryAsync(
            db,
            "select from_status, to_status, reason, changed_on, changed_by_email from identity.platform_tenant_history(@id)",
            r => new TenantStatusChangeDto(r.GetString(0), r.GetString(1), r.GetString(2), r.GetFieldValue<DateTimeOffset>(3), r.IsDBNull(4) ? null : r.GetString(4)),
            ct,
            ("id", id));
        return TypedResults.Ok(new PlatformTenantDetailDto(rows[0], history));
    }

    private static async Task<Results<Created<HospitalApprovedDto>, ValidationProblem, ProblemHttpResult>> CreateTenantAsync(
        PlatformCreateTenantRequest request, IdentityDbContext db, CancellationToken ct)
    {
        var errors = new Dictionary<string, string[]>();
        if (request.Code is null || !CodePattern().IsMatch(request.Code))
        {
            errors["code"] = [CodeRule];
        }

        if (string.IsNullOrWhiteSpace(request.Name) || request.Name.Trim().Length > 120)
        {
            errors["name"] = ["Hospital name is required (max 120 characters)."];
        }

        if (!IdentityValidators.IsIanaTimeZone(request.TimeZone))
        {
            errors["timeZone"] = ["Choose the hospital's IANA time zone, for example Asia/Kolkata."];
        }

        if (!IsEmail(request.AdminEmail))
        {
            errors["adminEmail"] = ["A valid first-admin email is required."];
        }

        if (errors.Count > 0)
        {
            return TypedResults.ValidationProblem(errors);
        }

        try
        {
            var rows = await RawSql.QueryAsync(
                db,
                "select tenant_id, invite_link_id, token, expires_on from identity.platform_create_tenant(@code, @name, @zone, @email)",
                r => new HospitalApprovedDto(r.GetGuid(0), Issued(r.GetGuid(1), r.GetString(2), r.GetFieldValue<DateTimeOffset>(3))),
                ct,
                ("code", request.Code),
                ("name", request.Name!.Trim()),
                ("zone", request.TimeZone),
                ("email", request.AdminEmail!.Trim()));
            return TypedResults.Created($"/api/v1/platform/tenants/{rows[0].TenantId}", rows[0]);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex, uniqueDetail: "A hospital with this code already exists. Choose another code.") is { } problem)
        {
            return problem;
        }
    }

    private static async Task<Results<NoContent, ValidationProblem, ProblemHttpResult>> SetStatusAsync(
        Guid id, string status, TenantStatusRequest request, IdentityDbContext db, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Reason) || request.Reason.Trim().Length is < 3 or > 500)
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["reason"] = [ReasonRule] });
        }

        try
        {
            await RawSql.ScalarAsync(db, "select identity.platform_set_tenant_status(@id, @status, @reason)", ct, ("id", id), ("status", status), ("reason", request.Reason));
            return TypedResults.NoContent();
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    private static async Task<Results<Ok<InviteLinkIssuedDto>, ValidationProblem, ProblemHttpResult>> ReissueAdminInviteAsync(
        Guid id, AdminInviteRequest request, IdentityDbContext db, CancellationToken ct)
    {
        if (!IsEmail(request.Email))
        {
            return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["email"] = ["A valid email is required."] });
        }

        try
        {
            var rows = await RawSql.QueryAsync(
                db,
                "select invite_link_id, token, expires_on from identity.platform_reissue_admin_invite(@id, @email)",
                r => Issued(r.GetGuid(0), r.GetString(1), r.GetFieldValue<DateTimeOffset>(2)),
                ct,
                ("id", id),
                ("email", request.Email!.Trim()));
            return TypedResults.Ok(rows[0]);
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    // --------------------------------------------------------------- validation ----
    internal const string EmailRegisteredDetail = "This email is already registered. Please sign in or contact support.";
    internal const string PossibleDuplicateDetail = "This request may duplicate an existing hospital. Confirm to approve it.";

    private const string CodeRule = "Code must be 2-40 lowercase letters, digits or hyphens, starting with a letter or digit.";
    private const string ReasonRule = "Give a reason (3-500 characters).";

    internal static bool IsEmail(string? email) =>
        !string.IsNullOrWhiteSpace(email) && email.Trim().Length <= 254 && EmailPattern().IsMatch(email.Trim());

    internal static Dictionary<string, string[]> Validate(HospitalSignupRequest r)
    {
        var errors = new Dictionary<string, string[]>();
        if (string.IsNullOrWhiteSpace(r.HospitalName) || r.HospitalName.Trim().Length is < 2 or > 120)
        {
            errors["hospitalName"] = ["Hospital name is required (2-120 characters)."];
        }

        if (!IdentityValidators.IsIanaTimeZone(r.TimeZone?.Trim()))
        {
            var suggestion = r.TimeZone is null ? null : Hms.SharedKernel.Time.TenantTimeZones.Suggest(r.TimeZone);
            errors["timeZone"] = [suggestion is null
                ? "Choose the hospital's IANA time zone, for example Asia/Kolkata."
                : $"Unknown time zone. Did you mean '{suggestion}'?"];
        }

        if (string.IsNullOrWhiteSpace(r.ContactName) || r.ContactName.Trim().Length is < 2 or > 120)
        {
            errors["contactName"] = ["Contact name is required (2-120 characters)."];
        }

        if (!IsEmail(r.ContactEmail))
        {
            errors["contactEmail"] = ["A valid email is required."];
        }

        if (r.Phone is null || !PhonePattern().IsMatch(r.Phone.Trim()))
        {
            errors["phone"] = ["Phone: 7-20 digits, spaces, brackets or dashes; may start with +."];
        }

        if (string.IsNullOrWhiteSpace(r.City) || r.City.Trim().Length is < 2 or > 80)
        {
            errors["city"] = ["City is required (2-80 characters)."];
        }

        return errors;
    }

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{1,39}$")]
    private static partial Regex CodePattern();

    [GeneratedRegex(@"^[^@\s]+@[^@\s]+\.[^@\s]+$")]
    private static partial Regex EmailPattern();

    [GeneratedRegex(@"^\+?[0-9][0-9 ()-]{6,19}$")]
    internal static partial Regex PhonePattern();

    [GeneratedRegex("^[0-9a-f]{64}$")]
    internal static partial Regex TokenPattern();

    /// <summary>True when Postgres raised <paramref name="sqlState"/> with exactly <paramref name="message"/> (no interpolated hospital data).</summary>
    private static bool IsDbSignal(Exception ex, string sqlState, string message)
    {
        var db = HmsProblems.FindDbError(ex);
        if (db?.SqlState != sqlState)
        {
            return false;
        }

        var text = db.GetType().GetProperty("MessageText")?.GetValue(db) as string ?? db.Message;
        return string.Equals(text, message, StringComparison.Ordinal);
    }
}
