using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;
using Npgsql;

namespace Hms.Modules.Identity.Endpoints;

internal static class PostgresErrors
{
    public static PostgresException? Find(Exception ex) => ex switch
    {
        PostgresException pg => pg,
        DbUpdateException { InnerException: PostgresException pg } => pg,
        _ => null,
    };

    public static ProblemHttpResult? ToProblem(Exception ex, string conflictDetail) => Find(ex)?.SqlState switch
    {
        PostgresErrorCodes.UniqueViolation => TypedResults.Problem(title: "Conflict", detail: conflictDetail, statusCode: StatusCodes.Status409Conflict),
        PostgresErrorCodes.InsufficientPrivilege => TypedResults.Problem(title: "Forbidden", detail: "Not permitted for your memberships.", statusCode: StatusCodes.Status403Forbidden),
        PostgresErrorCodes.ForeignKeyViolation or PostgresErrorCodes.CheckViolation =>
            TypedResults.Problem(title: "Invalid reference", detail: "A referenced value is invalid for this hospital.", statusCode: StatusCodes.Status400BadRequest),
        _ => null,
    };
}
