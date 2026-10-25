using System.Text.Json;
using Hms.Modules.Privacy.Persistence;
using Hms.Platform.Http;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.AspNetCore.Routing;

namespace Hms.Modules.Privacy.Endpoints;

public static class PrivacyEndpoints
{
    public static RouteGroupBuilder MapPrivacyEndpoints(this RouteGroupBuilder api)
    {
        var root = api.MapGroup("/privacy").WithTags("Privacy").RequireTenant().WithDbTransaction<PrivacyDbContext>();
        root.MapGet("/consent-notices", (PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            ExecAny(db, tenant, [HmsPermissions.PrivacyView, HmsPermissions.PrivacyNotice],
                "select privacy.list_notices(@t::uuid)::text", ct));
        root.MapGet("/consent-notices/current", (string? language, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            ExecAny(db, tenant, [HmsPermissions.PrivacyView, HmsPermissions.PrivacyNotice, HmsPermissions.PrivacyConsent],
                "select privacy.current_notice(@t::uuid, @lang::text)::text", ct, ("lang", language)));
        root.MapPost("/consent-notices", (HttpRequest request, JsonElement body, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Write(request, body, db, tenant, HmsPermissions.PrivacyNotice,
                "select privacy.create_notice(@t::uuid, @k::uuid, @b::jsonb)::text", true, ct));
        root.MapPost("/consent-notices/{id:guid}/publish", (Guid id, HttpRequest request, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Write(request, default, db, tenant, HmsPermissions.PrivacyNotice,
                "select privacy.publish_notice(@t::uuid, @k::uuid, @id::uuid)::text", false, ct, ("id", id)));

        root.MapGet("/patients/{patientId:guid}/consents", (Guid patientId, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.PrivacyView,
                "select privacy.list_consents(@t::uuid, @p::uuid)::text", ct, ("p", patientId)));
        root.MapPost("/patients/{patientId:guid}/consents", (Guid patientId, HttpRequest request, JsonElement body, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Write(request, body, db, tenant, HmsPermissions.PrivacyConsent,
                "select privacy.record_consents(@t::uuid, @k::uuid, @p::uuid, @b::jsonb)::text", true, ct, ("p", patientId)));
        root.MapPost("/patients/{patientId:guid}/consents/{purpose}/withdraw", (Guid patientId, string purpose, HttpRequest request, JsonElement body, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Write(request, body, db, tenant, HmsPermissions.PrivacyConsent,
                "select privacy.withdraw_consent(@t::uuid, @k::uuid, @p::uuid, @purpose::text, @b::jsonb)::text", true, ct,
                ("p", patientId), ("purpose", purpose)));
        root.MapPost("/patients/{patientId:guid}/consent-links", (Guid patientId, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.PrivacyConsent,
                "select privacy.create_consent_link(@t::uuid, @p::uuid)::text", ct, ("p", patientId)));
        root.MapGet("/patients/{patientId:guid}/consents/{purpose}/allowed", (Guid patientId, string purpose, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.PrivacyView,
                "select to_jsonb(privacy.consent_allows_v1(@t::uuid, @p::uuid, @purpose::text))::text", ct,
                ("p", patientId), ("purpose", purpose)));

        root.MapGet("/rights-requests", (string? status, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.PrivacyView,
                "select privacy.list_rights_requests(@t::uuid, @s::text)::text", ct, ("s", status)));
        root.MapPost("/rights-requests", (HttpRequest request, JsonElement body, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Write(request, body, db, tenant, HmsPermissions.PrivacyRequest,
                "select privacy.create_rights_request(@t::uuid, @k::uuid, @b::jsonb)::text", true, ct));
        root.MapGet("/rights-requests/{id:guid}", (Guid id, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.PrivacyView,
                "select privacy.get_rights_request(@t::uuid, @id::uuid)::text", ct, ("id", id)));
        root.MapPost("/rights-requests/{id:guid}/verify", (Guid id, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.PrivacyFulfil,
                "select privacy.verify_rights_request(@t::uuid, @id::uuid)::text", ct, ("id", id)));
        root.MapPost("/rights-requests/{id:guid}/fulfil", (Guid id, JsonElement body, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.PrivacyFulfil,
                "select privacy.fulfil_rights_request(@t::uuid, @id::uuid, @b::jsonb)::text", ct,
                ("id", id), ("b", body.GetRawText())));
        root.MapPost("/rights-requests/{id:guid}/close", (Guid id, JsonElement body, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.PrivacyFulfil,
                "select privacy.close_rights_request(@t::uuid, @id::uuid, @b::jsonb)::text", ct,
                ("id", id), ("b", body.GetRawText())));
        root.MapPost("/rights-requests/{id:guid}/erasure-approvals", (Guid id, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.PrivacyErase,
                "select privacy.approve_erasure(@t::uuid, @id::uuid)::text", ct, ("id", id)));
        root.MapPost("/rights-requests/{id:guid}/execute-erasure", (Guid id, HttpRequest request, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Write(request, default, db, tenant, HmsPermissions.PrivacyErase,
                "select privacy.execute_erasure(@t::uuid, @k::uuid, @id::uuid)::text", false, ct, ("id", id)));
        root.MapGet("/rights-requests/{id:guid}/access-export", (Guid id, PrivacyDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.PrivacyFulfil,
                "select privacy.access_export(@t::uuid, @id::uuid)::text", ct, ("id", id)));

        var pub = api.MapGroup("/privacy/public").WithTags("Privacy").AllowAnonymous()
            .RequireRateLimiting(PrivacyModule.PublicPolicy)
            .WithDbTransaction<PrivacyDbContext>();
        pub.MapGet("/consents/{token}", (string token, PrivacyDbContext db, CancellationToken ct) =>
            Public(db, "select privacy.public_consent_preview(@token::text)::text", ct, ("token", token)));
        pub.MapPost("/consents/{token}", (string token, JsonElement body, PrivacyDbContext db, CancellationToken ct) =>
        {
            if (PrivacyCodeRules.HasPublicTenant(body))
            {
                return Task.FromResult<IResult>(HmsProblems.BadRequest(
                    HmsProblems.Codes.InvalidParameter, "The hospital and the patient come from the link, not from the request."));
            }

            return Public(db, "select privacy.submit_public_consent(@token::text, @b::jsonb)::text", ct,
                ("token", token), ("b", body.GetRawText()));
        });
        return api;
    }

    private static Task<IResult> Write(
        HttpRequest request, JsonElement body, PrivacyDbContext db, ITenantContext tenant, string permission, string sql,
        bool checkCode, CancellationToken ct, params (string Name, object? Value)[] extra)
    {
        if (checkCode && body.ValueKind == JsonValueKind.Object && PrivacyCodeRules.HasClientSuppliedCode(body))
        {
            return Task.FromResult<IResult>(HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, PrivacyCodeRules.ClientSuppliedCodeDetail));
        }

        if (!request.Headers.TryGetValue("Idempotency-Key", out var raw) || !Guid.TryParse(raw, out var key))
        {
            return Task.FromResult<IResult>(HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "Idempotency-Key must be a UUID."));
        }

        var args = new List<(string Name, object? Value)> { ("k", key) };
        args.AddRange(extra);

        if (body.ValueKind is JsonValueKind.Object or JsonValueKind.Array)
        {
            args.Add(("b", body.GetRawText()));
        }

        return Exec(db, tenant, permission, sql, ct, [.. args]);
    }

    private static Task<IResult> ExecAny(
        PrivacyDbContext db, ITenantContext tenant, string[] permissions, string sql, CancellationToken ct, params (string Name, object? Value)[] extra)
    {
        if (!permissions.Any(tenant.Can))
        {
            return Task.FromResult<IResult>(HmsProblems.Forbidden());
        }

        return Run(db, sql, ct, WithTenant(tenant, extra));
    }

    private static Task<IResult> Exec(
        PrivacyDbContext db, ITenantContext tenant, string permission, string sql, CancellationToken ct, params (string Name, object? Value)[] extra)
    {
        if (!tenant.Can(permission))
        {
            return Task.FromResult<IResult>(HmsProblems.Forbidden());
        }

        return Run(db, sql, ct, WithTenant(tenant, extra));
    }

    private static (string Name, object? Value)[] WithTenant(ITenantContext tenant, (string Name, object? Value)[] extra)
    {
        var args = new (string Name, object? Value)[extra.Length + 1];
        args[0] = ("t", tenant.TenantId);
        extra.CopyTo(args, 1);
        return args;
    }

    private static Task<IResult> Public(PrivacyDbContext db, string sql, CancellationToken ct, params (string Name, object? Value)[] args) =>
        Run(db, sql, ct, args);

    private static async Task<IResult> Run(PrivacyDbContext db, string sql, CancellationToken ct, params (string Name, object? Value)[] args)
    {
        try
        {
            var value = await RawSql.ScalarAsync(db, sql, ct, args);
            return Results.Text(value?.ToString() ?? "null", "application/json");
        }
        catch (Exception ex) when (PrivacyProblems.From(ex) is { } problem)
        {
            return problem;
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }
}
