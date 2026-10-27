// cross-schema: approved (the endpoints call clinical.* functions; the clinical schema is owned by the
// scheduling service, see docs/adr/0003-clinical-consultations-in-scheduling.md)
using System.Text.Json;
using Hms.Modules.Appointments.Persistence;
using Hms.Platform.Http;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;

namespace Hms.Modules.Appointments.Endpoints;

/// <summary>
/// Consultation + prescription v1 (<c>/api/v1/consultations</c>). The tenant always comes from the
/// server session (<see cref="ITenantContext"/>), never the request. Every rule (doctor-own write,
/// branch scope, immutability, optimistic concurrency) is enforced again in the clinical.* SQL functions.
/// </summary>
public static class ConsultationEndpoints
{
    public sealed record StartRequest(Guid? QueueEntryId, Guid? AppointmentId);
    public sealed record FinalizeRequest(int RowVersion);

    public static RouteGroupBuilder MapConsultationEndpoints(this RouteGroupBuilder api)
    {
        var g = api.MapGroup("/consultations").WithTags("Consultations").RequireTenant().WithDbTransaction<AppointmentsDbContext>();

        g.MapPost("/", (StartRequest body, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.ClinicalWrite,
                "select clinical.start_consultation(@t::uuid, @q::uuid, @a::uuid)::text", ct,
                ("q", body.QueueEntryId), ("a", body.AppointmentId)));

        g.MapGet("/{id:guid}", (Guid id, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.ClinicalView,
                "select clinical.get_consultation(@t::uuid, @id::uuid)::text", ct, ("id", id)));

        g.MapPut("/{id:guid}", (Guid id, JsonElement body, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct) =>
        {
            if (body.ValueKind != JsonValueKind.Object
                || !body.TryGetProperty("rowVersion", out var rv) || rv.ValueKind != JsonValueKind.Number || !rv.TryGetInt32(out var rowVersion))
            {
                return Task.FromResult<IResult>(HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "rowVersion is required."));
            }

            return Exec(db, tenant, HmsPermissions.ClinicalWrite,
                "select clinical.save_consultation(@t::uuid, @id::uuid, @rv::integer, @b::jsonb)::text", ct,
                ("id", id), ("rv", rowVersion), ("b", body.GetRawText()));
        });

        g.MapPost("/{id:guid}/finalize", (Guid id, FinalizeRequest body, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.ClinicalWrite,
                "select clinical.finalize_consultation(@t::uuid, @id::uuid, @rv::integer)::text", ct,
                ("id", id), ("rv", body.RowVersion)));

        g.MapPost("/{id:guid}/revisions", (Guid id, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.ClinicalWrite,
                "select clinical.revise_consultation(@t::uuid, @id::uuid)::text", ct, ("id", id)));

        g.MapGet("/{id:guid}/print", (Guid id, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.ClinicalView,
                "select clinical.consultation_print(@t::uuid, @id::uuid)::text", ct, ("id", id)));

        // Patient history. Lives under /consultations (not /patients/...) so the edge routes it to scheduling.
        g.MapGet("/", (Guid patientId, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.ClinicalView,
                "select clinical.patient_consultations(@t::uuid, @p::uuid)::text", ct, ("p", patientId)));

        // Vitals (#104): nurse/doctor record against a visit; history per patient or per visit. Under
        // /consultations so the edge routes it to scheduling. Range rules live in clinical.record_vitals.
        g.MapPost("/vitals", (JsonElement body, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct) =>
        {
            if (body.ValueKind != JsonValueKind.Object
                || !body.TryGetProperty("queueEntryId", out var q) || q.ValueKind != JsonValueKind.String || !q.TryGetGuid(out var queueEntryId))
            {
                return Task.FromResult<IResult>(HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "queueEntryId is required."));
            }

            return Exec(db, tenant, HmsPermissions.ClinicalVitals,
                "select clinical.record_vitals(@t::uuid, @q::uuid, @b::jsonb)::text", ct,
                ("q", queueEntryId), ("b", body.GetRawText()));
        });

        g.MapGet("/vitals", (Guid? patientId, Guid? queueEntryId, AppointmentsDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.ClinicalView,
                "select clinical.list_vitals(@t::uuid, @p::uuid, @q::uuid)::text", ct, ("p", patientId), ("q", queueEntryId)));

        return api;
    }

    private static async Task<IResult> Exec(
        AppointmentsDbContext db, ITenantContext tenant, string permission, string sql, CancellationToken ct,
        params (string Name, object? Value)[] extra)
    {
        if (!tenant.Can(permission))
        {
            return HmsProblems.Forbidden();
        }

        try
        {
            var value = await RawSql.ScalarAsync(db, sql, ct, [("t", tenant.TenantId), .. extra]);
            return Results.Text(value?.ToString() ?? "null", "application/json");
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }
}
