using System.Text.Json;
using System.Text.Json.Nodes;
using Hms.Platform.Http;
using Microsoft.AspNetCore.Http;

namespace Hms.Modules.Billing.Endpoints;

/// <summary>
/// Reads required fields from a JSON request body so a missing or malformed field
/// becomes a 400 invalid_parameter instead of an unhandled 500.
/// </summary>
public static class BodyFields
{
    public static bool TryGuid(JsonElement body, string name, out Guid value)
    {
        value = Guid.Empty;
        return body.ValueKind == JsonValueKind.Object
            && body.TryGetProperty(name, out var p)
            && p.ValueKind == JsonValueKind.String
            && p.TryGetGuid(out value);
    }

    public static bool TryString(JsonElement body, string name, out string value)
    {
        value = "";
        if (body.ValueKind != JsonValueKind.Object || !body.TryGetProperty(name, out var p) || p.ValueKind != JsonValueKind.String)
            return false;
        value = p.GetString() ?? "";
        return value.Trim().Length > 0;
    }

    public static bool TryObject(JsonElement body, string name, out string raw)
    {
        raw = "";
        if (body.ValueKind != JsonValueKind.Object || !body.TryGetProperty(name, out var p) || p.ValueKind != JsonValueKind.Object)
            return false;
        raw = p.GetRawText();
        return true;
    }

    public static Task<IResult> Invalid(string name, string kind) =>
        Task.FromResult<IResult>(HmsProblems.BadRequest(HmsProblems.Codes.InvalidParameter, $"{name} must be {kind}."));

    /// <summary>
    /// Stamps the session tenant onto an event payload. The client never chooses the tenant:
    /// a payload that names a different tenant is rejected, otherwise tenant_id is set from the session.
    /// </summary>
    public static bool TryStampTenant(string payloadRaw, Guid sessionTenant, out string stamped)
    {
        stamped = "";
        if (JsonNode.Parse(payloadRaw) is not JsonObject obj) return false;
        if (obj.TryGetPropertyValue("tenant_id", out var given) && given is not null)
        {
            var text = given.GetValueKind() == JsonValueKind.String ? given.GetValue<string>() : null;
            if (!Guid.TryParse(text, out var g) || g != sessionTenant) return false;
        }
        obj["tenant_id"] = sessionTenant.ToString();
        stamped = obj.ToJsonString();
        return true;
    }
}
