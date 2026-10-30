using Hms.Platform.Http;

namespace Hms.UnitTests;

/// <summary>#111: database rule errors become field or rule messages instead of a generic one.</summary>
public class HmsProblemsRuleMessageTests
{
    private sealed class PgLikeException(string sqlState, string message, string? schema = null, string? table = null, string? constraint = null)
        : System.Data.Common.DbException(message)
    {
        public override string SqlState { get; } = sqlState;
        public string MessageText { get; } = message;
        public string? SchemaName { get; } = schema;
        public string? TableName { get; } = table;
        public string? ConstraintName { get; } = constraint;
    }

    [Fact]
    public void A_mapped_check_constraint_is_a_field_error()
    {
        var problem = HmsProblems.FromDatabase(new PgLikeException("23514",
            "new row for relation \"patients\" violates check constraint \"patients_sex_valid\"", "patient", "patients", "patients_sex_valid"))!;
        Assert.Equal(400, problem.StatusCode);
        Assert.Equal("check_violation", problem.ProblemDetails.Extensions["code"]);
        Assert.Equal("patients_sex_valid", problem.ProblemDetails.Extensions["rule"]);
        var errors = Assert.IsType<Dictionary<string, string[]>>(problem.ProblemDetails.Extensions["errors"]);
        Assert.Equal("Sex must be one of: female, male, other, unknown.", Assert.Single(errors["sex"]));
        Assert.Equal(errors["sex"][0], problem.ProblemDetails.Detail);
    }

    [Fact]
    public void An_unmapped_check_constraint_names_the_rule_but_not_the_row()
    {
        var problem = HmsProblems.FromDatabase(new PgLikeException("23514",
            "new row for relation \"x\" violates check constraint \"x_two_cols\" Failing row contains (secret)", "s", "x", "x_two_cols"))!;
        Assert.Equal(400, problem.StatusCode);
        Assert.Contains("x_two_cols", problem.ProblemDetails.Detail, StringComparison.Ordinal);
        Assert.DoesNotContain("secret", problem.ProblemDetails.Detail, StringComparison.Ordinal);
        Assert.False(problem.ProblemDetails.Extensions.ContainsKey("errors"));
    }

    [Fact]
    public void A_check_raised_by_our_function_keeps_its_message()
    {
        var problem = HmsProblems.FromDatabase(new PgLikeException("23514", "allocations exceed the bill total"))!;
        Assert.Equal(400, problem.StatusCode);
        Assert.Equal("Allocations exceed the bill total.", problem.ProblemDetails.Detail);
    }

    [Theory]
    [InlineData("only admins can book outside working hours", "Only admins can book outside working hours.")]
    [InlineData("a cash refund of a digital payment needs a manager", "A cash refund of a digital payment needs a manager.")]
    [InlineData("outside your approval limit", "Outside your approval limit.")]
    public void Business_rule_403s_show_the_rule(string db, string shown)
    {
        var problem = HmsProblems.FromDatabase(new PgLikeException("42501", db))!;
        Assert.Equal(403, problem.StatusCode);
        Assert.Equal(shown, problem.ProblemDetails.Detail);
    }

    [Theory]
    [InlineData("permission denied for table patients")]
    [InlineData("permission denied")]
    [InlineData("new row violates row-level security policy for table \"bill\"")]
    [InlineData("")]
    public void Postgres_privilege_errors_stay_generic(string db)
    {
        var problem = HmsProblems.FromDatabase(new PgLikeException("42501", db))!;
        Assert.Equal(403, problem.StatusCode);
        Assert.Equal("The database rejected this operation for your memberships.", problem.ProblemDetails.Detail);
    }

    [Fact]
    public void Foreign_key_violations_keep_the_reference_message()
    {
        var problem = HmsProblems.FromDatabase(new PgLikeException("23503", "insert violates fk", "billing", "bill", "bill_account_fk"))!;
        Assert.Equal("invalid_reference", problem.ProblemDetails.Extensions["code"]);
        Assert.StartsWith("A referenced record does not exist", problem.ProblemDetails.Detail, StringComparison.Ordinal);
    }

    [Fact]
    public void Every_mapped_rule_has_a_camel_case_field_and_a_sentence()
    {
        Assert.True(DatabaseCheckRules.ByConstraint.Count > 200);
        foreach (var (key, rule) in DatabaseCheckRules.ByConstraint)
        {
            Assert.Equal(3, key.Split('.').Length);
            Assert.Matches("^[a-z][A-Za-z0-9]*$", rule.Field);
            Assert.EndsWith(".", rule.Message, StringComparison.Ordinal);
        }
    }
}
