using System.Text.Json;
using Hms.Modules.Patients.Endpoints;
using Hms.Modules.Patients.Registry;
using Hms.SharedKernel.Http;
using Microsoft.AspNetCore.Http.HttpResults;

namespace Hms.UnitTests;

public class Sprint2PrimitivesTests
{
    [Theory]
    [InlineData(null, null)]
    [InlineData("12345", null)]                    // < 7 digits
    [InlineData("123-4567", "1234567")]
    [InlineData("+91 98450-12345", "9845012345")]  // last 10 digits
    [InlineData("0091 (984) 501 2345", "9845012345")]
    [InlineData("ext only", null)]
    public void Phone_normalization_mirrors_the_db_function(string? input, string? expected) =>
        Assert.Equal(expected, PatientPhone.Normalize(input));

    [Theory]
    [InlineData("42501", 403, "forbidden")]
    [InlineData("P0002", 404, "not_found")]
    [InlineData("23505", 409, "duplicate_mrn")]
    [InlineData("23P01", 409, "appointment_overlap")]
    [InlineData("55000", 409, "invalid_state")]
    [InlineData("22023", 400, "invalid_parameter")]
    [InlineData("23503", 400, "invalid_reference")]
    [InlineData("23514", 400, "check_violation")]
    public void Sqlstates_map_to_the_contracted_http_status(string sqlState, int status, string code)
    {
        var problem = HmsProblems.FromDatabase(new FakeDbException(sqlState), HmsProblems.Codes.DuplicateMrn, HmsProblems.Codes.AppointmentOverlap);
        Assert.NotNull(problem);
        Assert.Equal(status, problem.StatusCode);
        Assert.Equal(code, problem.ProblemDetails.Extensions["code"]);
    }

    [Fact]
    public void Invalid_transition_check_violation_is_409_and_keeps_the_message()
    {
        var problem = HmsProblems.FromDatabase(new InvalidOperationException("wrapper", new FakeDbException("23514", "invalid_transition:completed->booked")))!;
        Assert.Equal(409, problem.StatusCode);
        Assert.Equal("invalid_transition", problem.ProblemDetails.Extensions["code"]);
        Assert.Contains("completed->booked", problem.ProblemDetails.Detail, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("40P01")] // deadlock detected (e.g. concurrent overlapping booking inserts on the exclusion constraint)
    [InlineData("40001")] // serialization failure
    public void Concurrency_aborts_are_409_with_the_endpoint_code(string sqlState)
    {
        var booking = HmsProblems.FromDatabase(
            // shape Npgsql's execution strategy throws for transient errors: IOE -> DbUpdateException -> PostgresException
            new InvalidOperationException(
                "An exception has been raised that is likely due to a transient failure.",
                new Microsoft.EntityFrameworkCore.DbUpdateException("save failed", new FakeDbException(sqlState))),
            exclusionCode: HmsProblems.Codes.AppointmentOverlap,
            concurrencyCode: HmsProblems.Codes.AppointmentOverlap,
            concurrencyDetail: "The practitioner is already booked for part of that time.")!;
        Assert.Equal(409, booking.StatusCode);
        Assert.Equal("appointment_overlap", booking.ProblemDetails.Extensions["code"]);
        Assert.Equal("The practitioner is already booked for part of that time.", booking.ProblemDetails.Detail);

        var generic = HmsProblems.FromDatabase(new FakeDbException(sqlState))!;
        Assert.Equal(409, generic.StatusCode);
        Assert.Equal("conflict", generic.ProblemDetails.Extensions["code"]);
    }

    [Fact]
    public void Unmapped_errors_are_not_swallowed()
    {
        Assert.Null(HmsProblems.FromDatabase(new FakeDbException("XX000")));
        Assert.Null(HmsProblems.FromDatabase(new InvalidOperationException("no db")));
    }

    [Fact]
    public void Patch_parser_distinguishes_absent_from_null()
    {
        var errors = new Dictionary<string, string[]>();
        using var doc = JsonDocument.Parse("""{"phone":null,"lastName":"X","dateOfBirth":"2001-02-03","tenantId":"ignored"}""");
        var patch = PatientPatch.Parse(doc.RootElement, errors);
        Assert.Empty(errors);
        Assert.True(patch.Phone.IsSet);
        Assert.Null(patch.Phone.Value);
        Assert.False(patch.Email.IsSet);
        Assert.Equal("keep", patch.Email.Or("keep"));
        Assert.Equal(new DateOnly(2001, 2, 3), patch.DateOfBirth.Value);
    }

    [Fact]
    public void Patch_parser_rejects_non_objects()
    {
        var errors = new Dictionary<string, string[]>();
        using var doc = JsonDocument.Parse("[1]");
        PatientPatch.Parse(doc.RootElement, errors);
        Assert.Contains("body", errors.Keys);
    }

    [Fact]
    public void Problem_helpers_set_status_and_code()
    {
        ProblemHttpResult conflict = HmsProblems.Conflict("x_code", "detail");
        Assert.Equal(409, conflict.StatusCode);
        Assert.Equal("x_code", conflict.ProblemDetails.Extensions["code"]);
        Assert.Equal(403, HmsProblems.Forbidden().StatusCode);
        Assert.Equal(404, HmsProblems.NotFound().StatusCode);
    }
}
