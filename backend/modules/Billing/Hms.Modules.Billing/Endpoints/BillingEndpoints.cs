using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hms.Modules.Billing.Payments;
using Hms.Modules.Billing.Persistence;
using Hms.Platform.Http;
using Hms.SharedKernel.Http;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;

namespace Hms.Modules.Billing.Endpoints;

public static class BillingEndpoints
{
    public static RouteGroupBuilder MapBillingEndpoints(this RouteGroupBuilder api)
    {
        var items = api.MapGroup("/service-items").WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();
        items.MapGet("/", (string? q, bool? includeInactive, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingView,
                "select billing.list_service_items(@t::uuid, @q::text, @i::boolean)::text", ct,
                ("q", string.IsNullOrWhiteSpace(q) ? null : q.Trim()),
                ("i", includeInactive ?? false)));
        items.MapGet("/tax-codes", (BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingPricelistManage, "select billing.list_tax_codes(@t::uuid)::text", ct));
        items.MapGet("/category-defaults", (BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingPricelistManage, "select billing.list_category_defaults(@t::uuid)::text", ct));
        items.MapPost("/", (JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
        {
            // Create and update both refuse a typed code. Allocation is billing.allocate_service_code.
            if (ServiceCodeRules.HasClientSuppliedCode(body))
            {
                return Task.FromResult<IResult>(HmsProblems.BadRequest(
                    HmsProblems.Codes.InvalidParameter, ServiceCodeRules.ClientSuppliedCodeDetail));
            }

            return Write(db, tenant, HmsPermissions.BillingPricelistManage, "select billing.upsert_service_item(@t::uuid, @b::jsonb)::text", body, ct);
        });

        var lists = api.MapGroup("/price-lists").WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();
        lists.MapGet("/", (BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingPricelistManage, "select billing.list_price_lists(@t::uuid)::text", ct));
        lists.MapPost("/", (JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Write(db, tenant, HmsPermissions.BillingPricelistManage, "select billing.upsert_price_list(@t::uuid, @b::jsonb)::text", body, ct));
        lists.MapGet("/items", (Guid? serviceItemId, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingPricelistManage,
                "select billing.list_prices(@t::uuid, @s::uuid)::text", ct, ("s", serviceItemId)));
        lists.MapPost("/items", (JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Write(db, tenant, HmsPermissions.BillingPricelistManage, "select billing.add_price(@t::uuid, @b::jsonb)::text", body, ct));
        lists.MapPost("/copy", (JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Write(db, tenant, HmsPermissions.BillingPricelistManage, "select billing.copy_price_list(@t::uuid, @b::jsonb)::text", body, ct));
        lists.MapPost("/import", (JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingPricelistManage, "select billing.import_prices(@t::uuid, @b::jsonb)::text", ct,
                ("b", ServiceCodeRules.WithoutImportCodes(body.GetRawText()))));
        lists.MapPut("/branches/{branchId:guid}/prefix", (Guid branchId, JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingPricelistManage,
                "select billing.set_branch_prefix(@t::uuid, @b::uuid, @p::text)::text", ct,
                ("b", branchId), ("p", body.GetProperty("docPrefix").GetString())));
        lists.MapGet("/branches/{branchId:guid}/profile", (Guid branchId, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingView,
                "select billing.branch_profile_json(@t::uuid, @br::uuid)::text", ct, ("br", branchId)));
        lists.MapPut("/branches/{branchId:guid}/profile", (Guid branchId, JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingPricelistManage,
                "select billing.set_branch_profile(@t::uuid, @br::uuid, @j::jsonb)::text", ct,
                ("br", branchId), ("j", body.GetRawText())));

        api.MapGet("/price", ResolvePriceAsync).WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();

        var accounts = api.MapGroup("/accounts").WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();
        accounts.MapPost("/", (JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Write(db, tenant, HmsPermissions.BillingBill, "select billing.open_account(@t::uuid, @b::jsonb)::text", body, ct));
        accounts.MapPost("/from-appointment", (JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingBill, "select billing.ensure_draft(@t::uuid, @a::uuid)::text", ct,
                ("a", body.GetProperty("appointmentId").GetGuid())));
        accounts.MapGet("/{patientId:guid}/summary", (Guid patientId, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingView, "select billing.patient_summary(@t::uuid, @p::uuid)::text", ct, ("p", patientId)));

        var bills = api.MapGroup("/bills").WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();
        bills.MapGet("/", (string? status, Guid? branchId, DateOnly? from, DateOnly? to, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingView,
                "select billing.list_bills(@t::uuid, @s::text, @br::uuid, @f::date, @u::date)::text", ct,
                ("s", status), ("br", branchId), ("f", from), ("u", to)));
        bills.MapGet("/{id:guid}", (Guid id, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingView, "select billing.bill_document(@t::uuid, @b::uuid)::text", ct, ("b", id)));
        bills.MapPut("/{id:guid}/place-of-supply", (Guid id, JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingBill,
                "select billing.set_place_of_supply(@t::uuid, @b::uuid, @s::text)::text", ct,
                ("b", id), ("s", body.GetProperty("stateCode").GetString())));
        bills.MapPost("/{id:guid}/lines", (Guid id, JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingBill, "select billing.add_line(@t::uuid, @b::uuid, @j::jsonb)::text", ct, ("b", id), ("j", body.GetRawText())));
        bills.MapDelete("/{id:guid}/lines/{lineId:guid}", (Guid id, Guid lineId, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingBill, "select billing.remove_line(@t::uuid, @b::uuid, @l::uuid)::text", ct, ("b", id), ("l", lineId)));
        bills.MapPost("/{id:guid}/finalize", (Guid id, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingBill, "select billing.finalize_bill(@t::uuid, @b::uuid)::text", ct, ("b", id)));
        bills.MapPost("/{id:guid}/cancel", (Guid id, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingBill, "select billing.cancel_draft(@t::uuid, @b::uuid)::text", ct, ("b", id)));
        bills.MapPost("/{id:guid}/credit-notes", (Guid id, JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingBill, "select billing.create_credit_note(@t::uuid, @b::uuid, @j::jsonb)::text", ct, ("b", id), ("j", body.GetRawText())));
        bills.MapPost("/{id:guid}/discounts", (Guid id, JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingDiscountRequest, "select billing.request_discount(@t::uuid, @b::uuid, @j::jsonb)::text", ct, ("b", id), ("j", body.GetRawText())));
        bills.MapPost("/{id:guid}/advances", (Guid id, JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingCollect, "select billing.apply_advance(@t::uuid, @b::uuid, @j::jsonb)::text", ct, ("b", id), ("j", body.GetRawText())));
        bills.MapPost("/{id:guid}/payment-links", CreateLinkAsync);

        api.MapPost("/payments", RecordPaymentAsync).WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();
        api.MapPost("/payments/{id:guid}/refunds", (Guid id, JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingRefund, "select billing.request_refund(@t::uuid, @p::uuid, @j::jsonb)::text", ct, ("p", id), ("j", body.GetRawText())))
            .WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();
        api.MapGet("/receipts/{id:guid}", (Guid id, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingView, "select billing.receipt_json(@p::uuid)::text", ct, ("p", id)))
            .WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();

        var approvals = api.MapGroup("/approvals").WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();
        approvals.MapGet("/settings", (BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingView, "select billing.approval_settings_json(@t::uuid)::text", ct));
        approvals.MapPut("/settings", (JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingApprove, "select billing.set_approval_settings(@t::uuid, @j::jsonb)::text", ct, ("j", body.GetRawText())));
        approvals.MapGet("/", (string? status, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingView, "select billing.list_approvals(@t::uuid, @s::text)::text", ct, ("s", status)));
        approvals.MapPost("/{id:guid}/decide", (Guid id, JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingApprove, "select billing.decide_approval(@t::uuid, @a::uuid, @j::jsonb)::text", ct, ("a", id), ("j", body.GetRawText())));

        var counters = api.MapGroup("/counters").WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();
        counters.MapPost("/", (JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Write(db, tenant, HmsPermissions.BillingCollect, "select billing.open_counter(@t::uuid, @b::jsonb)::text", body, ct));

        var sessions = api.MapGroup("/counter-sessions").WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();
        sessions.MapGet("/open", (Guid branchId, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingCollect, "select billing.find_cashier_session(@t::uuid, @b::uuid)::text", ct, ("b", branchId)));
        sessions.MapPost("/ensure", (JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingCollect, "select billing.ensure_cashier_session(@t::uuid, @b::uuid)::text", ct,
                ("b", body.GetProperty("branchId").GetGuid())));
        sessions.MapPost("/", (JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Write(db, tenant, HmsPermissions.BillingCollect, "select billing.open_session(@t::uuid, @b::jsonb)::text", body, ct));
        sessions.MapPost("/{id:guid}/close", (Guid id, JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingCollect, "select billing.close_session(@t::uuid, @s::uuid, @j::jsonb)::text", ct, ("s", id), ("j", body.GetRawText())));
        sessions.MapPost("/{id:guid}/reconcile", (Guid id, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingCounterReconcile, "select billing.reconcile_session(@t::uuid, @s::uuid)::text", ct, ("s", id)));

        api.MapGet("/billing-reports/day-end", (Guid branchId, DateOnly date, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingView, "select billing.day_end(@t::uuid, @b::uuid, @d::date)::text", ct, ("b", branchId), ("d", date)))
            .WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();

        api.MapPost("/billing-events", (JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
            Exec(db, tenant, HmsPermissions.BillingBill,
                "select billing.consume_event(@e::uuid, @y::text, @j::jsonb)::text", ct,
                ("e", body.GetProperty("eventId").GetGuid()),
                ("y", body.GetProperty("eventType").GetString()),
                ("j", body.GetProperty("payload").GetRawText())))
            .WithTags("Billing").RequireTenant().WithDbTransaction<BillingDbContext>();

        var pub = api.MapGroup("/billing-public").WithTags("Billing").AllowAnonymous().WithDbTransaction<BillingDbContext>();
        pub.MapGet("/links/{token}", PublicLinkAsync);
        pub.MapPost("/webhooks/{provider}", WebhookAsync);
        return api;
    }

    private static Task<IResult> ResolvePriceAsync(
        Guid branchId, Guid serviceItemId, Guid? practitionerId, DateOnly? on, BillingDbContext db, ITenantContext tenant, CancellationToken ct) =>
        Exec(db, tenant, HmsPermissions.BillingView,
            "select billing.resolve_price(@t::uuid, @b::uuid, @s::uuid, @p::uuid, coalesce(@d::date, billing.branch_day(@b)))::text", ct,
            ("b", branchId), ("s", serviceItemId), ("p", practitionerId), ("d", on));

    private static async Task<IResult> RecordPaymentAsync(HttpRequest request, JsonElement body, BillingDbContext db, ITenantContext tenant, CancellationToken ct)
    {
        if (!request.Headers.TryGetValue("Idempotency-Key", out var raw) || !Guid.TryParse(raw, out var key))
        {
            return HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "Idempotency-Key must be a UUID.");
        }

        return await Exec(db, tenant, HmsPermissions.BillingCollect,
            "select billing.record_payment(@t::uuid, @k::uuid, @j::jsonb)::text", ct,
            ("k", key), ("j", body.GetRawText()));
    }

    private static async Task<IResult> CreateLinkAsync(
        Guid id, JsonElement body, BillingDbContext db, ITenantContext tenant, IPaymentProvider provider, IBillShareSender sender, CancellationToken ct)
    {
        var (error, json) = await Query(db, tenant, HmsPermissions.BillingCollect,
            "select billing.create_payment_link(@t::uuid, @b::uuid, @j::jsonb)::text", ct, ("b", id), ("j", body.GetRawText()));
        if (error is not null || json is null)
        {
            return error!;
        }

        var node = JsonNode.Parse(json)!.AsObject();
        var channel = node["channel"]?.GetValue<string>() ?? "link";
        var bill = await RawSql.ScalarAsync(db, "select billing.bill_document(@t::uuid, @b::uuid)::text", ct, ("t", tenant.TenantId), ("b", id));
        var due = JsonNode.Parse(bill?.ToString() ?? "{}")?["duePaise"]?.GetValue<long>() ?? 0;
        node["upiUri"] = provider.UpiUri(due, node["providerOrderId"]?.GetValue<string>() ?? "");
        if (channel is "whatsapp" or "sms")
        {
            var destination = body.TryGetProperty("destination", out var dest) ? dest.GetString() ?? "" : "";
            var share = await sender.SendAsync(channel, destination, node["path"]?.GetValue<string>() ?? "", ct);
            node["shareStatus"] = share.Status;
        }

        return Json(node.ToJsonString());
    }

    private static async Task<IResult> PublicLinkAsync(string token, BillingDbContext db, CancellationToken ct)
    {
        try
        {
            var value = await RawSql.ScalarAsync(db, "select billing.public_link(@t::text)::text", ct, ("t", token));
            return Json(value?.ToString() ?? "null");
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    private static async Task<IResult> WebhookAsync(
        string provider, HttpRequest request, BillingDbContext db, IPaymentProvider payments, TimeProvider clock, CancellationToken ct)
    {
        var bytes = await ReadBodyAsync(request, ct);
        if (bytes is null)
        {
            return HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, "Webhook body is too large.");
        }

        if (!payments.VerifyWebhook(provider, bytes, request.Headers[WebhookSignature.HeaderName].ToString(), clock.GetUtcNow()))
        {
            return Results.Unauthorized();
        }

        var body = Encoding.UTF8.GetString(bytes);
        try
        {
            // Anonymous HTTP starts as anon. HMAC is already checked, so this transaction
            // switches to the billing service role. anon itself cannot execute apply_webhook,
            // which keeps the Data API from applying a payment without the signature check.
            await RawSql.ScalarAsync(db, "select set_config('role', 'hms_svc_billing', true)", ct);
            var value = await RawSql.ScalarAsync(
                db,
                "select billing.apply_webhook(@p::text, @b::jsonb)::text",
                ct,
                ("p", provider),
                ("b", body));
            return Json(value?.ToString() ?? "null");
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex) is { } problem)
        {
            return problem;
        }
    }

    private static async Task<byte[]?> ReadBodyAsync(HttpRequest request, CancellationToken ct)
    {
        const int maxBytes = 65_536;
        request.EnableBuffering();
        using var buffer = new MemoryStream();
        var rented = new byte[8192];
        int read;
        while ((read = await request.Body.ReadAsync(rented.AsMemory(), ct)) > 0)
        {
            if (buffer.Length + read > maxBytes)
            {
                return null;
            }

            buffer.Write(rented, 0, read);
        }

        return buffer.ToArray();
    }

    private static Task<IResult> Write(BillingDbContext db, ITenantContext tenant, string permission, string sql, JsonElement body, CancellationToken ct) =>
        Exec(db, tenant, permission, sql, ct, ("b", body.GetRawText()));

    private static async Task<IResult> Exec(
        BillingDbContext db, ITenantContext tenant, string permission, string sql, CancellationToken ct, params (string Name, object? Value)[] extra)
    {
        var (error, json) = await Query(db, tenant, permission, sql, ct, extra);
        return error ?? Json(json!);
    }

    private static async Task<(IResult? Error, string? Json)> Query(
        BillingDbContext db, ITenantContext tenant, string permission, string sql, CancellationToken ct, params (string Name, object? Value)[] extra)
    {
        if (!tenant.Can(permission))
        {
            return (HmsProblems.Forbidden(), null);
        }

        var args = new List<(string Name, object? Value)>(extra.Length + 1);
        if (sql.Contains("@t", StringComparison.Ordinal))
        {
            args.Add(("t", tenant.TenantId));
        }

        args.AddRange(extra);
        try
        {
            var value = await RawSql.ScalarAsync(db, sql, ct, [.. args]);
            return (null, value?.ToString() ?? "null");
        }
        catch (Exception ex) when (HmsProblems.FromDatabase(ex, exclusionCode: "price_overlap", exclusionDetail: "That price overlaps an existing effective period.") is { } problem)
        {
            return (problem, null);
        }
    }

    private static IResult Json(string body) => Results.Text(body, "application/json");
}
