using Hms.Platform.Http;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;

namespace Hms.Modules.Privacy.Endpoints;

/// <summary>
/// Maps privacy.fail (SQLSTATE P0001, message "code|detail") onto the DPDP status codes.
/// HmsProblems leaves P0001 unmapped so a privacy-only code does not leak into other services.
/// </summary>
internal static class PrivacyProblems
{
    public static ProblemHttpResult? From(Exception ex)
    {
        var db = HmsProblems.FindDbError(ex);
        if (db is null || db.SqlState != "P0001")
        {
            return null;
        }

        var text = db.GetType().GetProperty("MessageText")?.GetValue(db) as string ?? db.Message;
        return FromMessage(text);
    }

    internal static ProblemHttpResult? FromMessage(string? message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return null;
        }

        var pipe = message.IndexOf('|', StringComparison.Ordinal);
        if (pipe <= 0)
        {
            return null;
        }

        var code = message[..pipe];
        if (code.Contains(' ', StringComparison.Ordinal) || code.Contains(':', StringComparison.Ordinal))
        {
            var marker = code.LastIndexOf(':');
            code = marker >= 0 ? code[(marker + 1)..].Trim() : code.Trim();
        }

        var detail = message[(pipe + 1)..].Trim();
        if (detail.Length > 300)
        {
            detail = detail[..300];
        }

        return code switch
        {
            "invalid_parameter" => HmsProblems.BadRequest(code, detail),
            "guardian_required" or "notice_not_current" or "identity_not_verified" =>
                Problem(StatusCodes.Status422UnprocessableEntity, "Unprocessable entity", detail, code),
            "no_published_notice" => Problem(StatusCodes.Status404NotFound, "Not found", detail, code),
            "link_expired" => Problem(StatusCodes.Status410Gone, "Gone", detail, code),
            "not_granted" or "published_immutable" or "second_approver_required" or "invalid_state" =>
                HmsProblems.Conflict(code, detail),
            _ => null,
        };
    }

    private static ProblemHttpResult Problem(int status, string title, string detail, string code) =>
        TypedResults.Problem(title: title, detail: detail, statusCode: status, extensions: new Dictionary<string, object?> { ["code"] = code });
}
