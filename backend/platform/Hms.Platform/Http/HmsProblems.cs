using System.Data.Common;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;

namespace Hms.Platform.Http;

/// <summary>
/// RFC 7807 problem results with a machine-readable <c>code</c> extension, plus the Sprint 2
/// PostgreSQL SQLSTATE → HTTP mapping (SPRINT2-CONTRACT.md §0 and API §A.1):
/// 42501→403, P0002→404, 23505/23P01/55000/23514(invalid_transition:)→409, 22023/23503/23514→400,
/// 40P01 (deadlock) / 40001 (serialization failure)→409 (the transaction was rolled back; the caller may retry).
/// </summary>
public static class HmsProblems
{
    public static class Codes
    {
        public const string Forbidden = "forbidden";
        public const string NotFound = "not_found";
        public const string InvalidParameter = "invalid_parameter";
        public const string InvalidReference = "invalid_reference";
        public const string CheckViolation = "check_violation";
        public const string Conflict = "conflict";
        public const string DuplicateMrn = "duplicate_mrn";
        public const string AlreadyCheckedIn = "already_checked_in";
        public const string ScheduleOverlap = "schedule_overlap";
        public const string AppointmentOverlap = "appointment_overlap";
        public const string InvalidTransition = "invalid_transition";
        public const string InvalidState = "invalid_state";
    }

    public static class SqlStates
    {
        public const string InsufficientPrivilege = "42501";
        public const string NoDataFound = "P0002";
        public const string UniqueViolation = "23505";
        public const string ExclusionViolation = "23P01";
        public const string CheckViolation = "23514";
        public const string ForeignKeyViolation = "23503";
        public const string ObjectNotInPrerequisiteState = "55000";
        public const string InvalidParameterValue = "22023";
        public const string DeadlockDetected = "40P01";
        public const string SerializationFailure = "40001";
    }

    public static ProblemHttpResult Forbidden(string? detail = null) =>
        Problem(StatusCodes.Status403Forbidden, "Forbidden", detail ?? "Your role does not permit this action.", Codes.Forbidden);

    public static ProblemHttpResult NotFound(string? detail = null) =>
        Problem(StatusCodes.Status404NotFound, "Not found", detail ?? "The resource does not exist.", Codes.NotFound);

    public static ProblemHttpResult Conflict(string code, string detail) =>
        Problem(StatusCodes.Status409Conflict, "Conflict", detail, code);

    public static ProblemHttpResult BadRequest(string code, string detail) =>
        Problem(StatusCodes.Status400BadRequest, "Bad request", detail, code);

    /// <summary>Finds the PostgreSQL error (any <see cref="DbException"/> with a SQLSTATE) in the exception chain.</summary>
    public static DbException? FindDbError(Exception? ex)
    {
        for (var e = ex; e is not null; e = e.InnerException)
        {
            if (e is DbException { SqlState: not null } db)
            {
                return db;
            }
        }

        return null;
    }

    /// <summary>
    /// Maps a database error to a problem result, or null when it is not a mapped SQLSTATE (rethrow).
    /// <paramref name="uniqueCode"/> / <paramref name="exclusionCode"/> name the 409 <c>code</c> for
    /// 23505 / 23P01 on this endpoint. <paramref name="concurrencyCode"/> names the 409 <c>code</c> for
    /// 40P01 / 40001: PostgreSQL aborted the transaction because of a concurrent one (e.g. two overlapping
    /// inserts deadlocking while checking an exclusion constraint), so nothing was written.
    /// </summary>
    public static ProblemHttpResult? FromDatabase(
        Exception ex, string uniqueCode = Codes.Conflict, string exclusionCode = Codes.Conflict, string? uniqueDetail = null, string? exclusionDetail = null,
        string concurrencyCode = Codes.Conflict, string? concurrencyDetail = null)
    {
        var db = FindDbError(ex);
        if (db is null)
        {
            return null;
        }

        var message = MessageOf(db);
        return db.SqlState switch
        {
            SqlStates.InsufficientPrivilege => Forbidden("The database rejected this operation for your memberships."),
            SqlStates.NoDataFound => NotFound(),
            SqlStates.UniqueViolation => Conflict(uniqueCode, uniqueDetail ?? "A conflicting record already exists."),
            SqlStates.ExclusionViolation => Conflict(exclusionCode, exclusionDetail ?? "The time range overlaps an existing booking."),
            SqlStates.ObjectNotInPrerequisiteState => Conflict(Codes.InvalidState, Sanitize(message) ?? "The record is not in a state that allows this operation."),
            SqlStates.CheckViolation when message?.Contains("invalid_transition:", StringComparison.Ordinal) == true =>
                Conflict(Codes.InvalidTransition, Sanitize(message)!),
            SqlStates.CheckViolation => BadRequest(Codes.CheckViolation, "A value violates a database rule."),
            SqlStates.ForeignKeyViolation => BadRequest(Codes.InvalidReference, "A referenced record does not exist in this hospital (or was deleted)."),
            SqlStates.InvalidParameterValue => BadRequest(Codes.InvalidParameter, Sanitize(message) ?? "A parameter value is invalid."),
            SqlStates.DeadlockDetected or SqlStates.SerializationFailure =>
                Conflict(concurrencyCode, concurrencyDetail ?? "A concurrent change conflicted with this request. Reload and try again."),
            _ => null,
        };
    }

    // PostgresException.MessageText (no "SQLSTATE: " prefix) when available, without a hard Npgsql dependency here.
    private static string? MessageOf(DbException db)
    {
        var text = db.GetType().GetProperty("MessageText")?.GetValue(db) as string;
        return text ?? db.Message;
    }

    // DB messages for these states are authored by our own functions (no data values), keep them short.
    private static string? Sanitize(string? message) =>
        string.IsNullOrWhiteSpace(message) ? null : message.Length > 300 ? message[..300] : message;

    private static ProblemHttpResult Problem(int status, string title, string detail, string code) =>
        TypedResults.Problem(title: title, detail: detail, statusCode: status, extensions: new Dictionary<string, object?> { ["code"] = code });
}
