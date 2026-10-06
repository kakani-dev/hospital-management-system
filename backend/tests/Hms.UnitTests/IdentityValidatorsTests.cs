using Hms.Modules.Identity.Endpoints;

namespace Hms.UnitTests;

public class IdentityValidatorsTests
{
    [Theory]
    [InlineData("main", "Main Hospital", "Asia/Kolkata", true)]
    [InlineData("east-2", "East", "UTC", true)]
    [InlineData("Main", "Main", "UTC", false)] // uppercase
    [InlineData("a", "Main", "UTC", false)] // too short
    [InlineData("-lead", "Main", "UTC", false)]
    [InlineData("has space", "Main", "UTC", false)]
    [InlineData("main", "", "UTC", false)]
    [InlineData("main", "Main", "Mars/Olympus", false)]
    [InlineData(null, "Main", "UTC", false)]
    public void Create_branch(string? code, string? name, string? tz, bool valid) =>
        Assert.Equal(valid, IdentityValidators.Validate(new CreateBranchRequest(code, name, tz)).Count == 0);

    [Fact]
    public void Branch_name_length_is_capped() =>
        Assert.NotEmpty(IdentityValidators.Validate(new CreateBranchRequest("main", new string('x', 121), "UTC")));

    [Fact]
    public void Update_branch_allows_partial_updates_but_validates_given_fields()
    {
        Assert.Empty(IdentityValidators.Validate(new UpdateBranchRequest(null, null, false)));
        Assert.NotEmpty(IdentityValidators.Validate(new UpdateBranchRequest("  ", null, null)));
        Assert.NotEmpty(IdentityValidators.Validate(new UpdateBranchRequest(null, "Not/AZone", null)));
    }

    [Theory]
    [InlineData("doc@hospital.example", "doctor", true)]
    [InlineData("doc@hospital.example", "tenant_admin", true)]
    [InlineData("not-an-email", "doctor", false)]
    [InlineData("doc@hospital.example", "superuser", false)]
    [InlineData("doc@hospital.example", null, false)]
    [InlineData(null, "doctor", false)]
    public void Add_member(string? email, string? role, bool valid) =>
        Assert.Equal(valid, IdentityValidators.Validate(new AddMemberRequest(email, role, null)).Count == 0);

    [Theory]
    [InlineData("nurse", null, true)]
    [InlineData(null, "suspended", true)]
    [InlineData(null, "active", true)]
    [InlineData(null, "deleted", false)]
    [InlineData("root", null, false)]
    [InlineData(null, null, false)]
    public void Update_member(string? role, string? status, bool valid) =>
        Assert.Equal(valid, IdentityValidators.Validate(new UpdateMemberRequest(role, status)).Count == 0);
}
