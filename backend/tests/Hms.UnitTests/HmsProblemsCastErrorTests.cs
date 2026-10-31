using Hms.Platform.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Npgsql;
using Xunit;

namespace Hms.UnitTests;

/// <summary>A body value the database cannot cast is the caller's mistake: 400, not 500.</summary>
public class HmsProblemsCastErrorTests
{
    private static ProblemHttpResult? Map(string state, string message) =>
        HmsProblems.FromDatabase(new PostgresException(message, "ERROR", "ERROR", state));

    [Theory]
    [InlineData("22003", "integer out of range", HmsProblems.OutOfRangeDetail)]
    [InlineData("22P02", "invalid input syntax for type numeric: \"abc\"", HmsProblems.BadFormatDetail)]
    [InlineData("22007", "invalid input syntax for type date: \"x\"", HmsProblems.BadFormatDetail)]
    [InlineData("22008", "date/time field value out of range", HmsProblems.BadFormatDetail)]
    public void Cast_errors_are_400_without_raw_text(string state, string raw, string shown)
    {
        var p = Map(state, raw);
        Assert.NotNull(p);
        Assert.Equal(400, p!.StatusCode);
        Assert.Equal(shown, p.ProblemDetails.Detail);
        Assert.Equal(HmsProblems.Codes.InvalidParameter, p.ProblemDetails.Extensions["code"]);
    }

    [Fact]
    public void Unknown_states_still_fall_through() => Assert.Null(Map("XX000", "internal"));
}
