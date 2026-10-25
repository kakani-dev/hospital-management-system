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
    [InlineData("main", "Main", "India Standard Time", false)] // Windows id: Postgres AT TIME ZONE rejects it
    [InlineData("main", "Main", "Pacific Standard Time", false)]
    [InlineData("main", "Main", "Europe/London", true)]
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
        Assert.NotEmpty(IdentityValidators.Validate(new UpdateBranchRequest(null, "India Standard Time", null)));
        Assert.Empty(IdentityValidators.Validate(new UpdateBranchRequest(null, null, null, Address: "1 Synthetic Road")));
        Assert.NotEmpty(IdentityValidators.Validate(new UpdateBranchRequest(null, null, null, Address: " ")));
        Assert.NotEmpty(IdentityValidators.Validate(new UpdateBranchRequest(null, null, null, Address: new string('a', 301))));
    }

    [Fact]
    public void Hospital_update_accepts_a_calling_code_and_rejects_a_bare_one()
    {
        Assert.Empty(IdentityValidators.Validate(new UpdateTenantRequest(null, null, DefaultCountryCode: "+971")));
        Assert.NotEmpty(IdentityValidators.Validate(new UpdateTenantRequest(null, null, DefaultCountryCode: "91")));
        Assert.NotEmpty(IdentityValidators.Validate(new UpdateTenantRequest(null, null)));
    }

    [Theory]
    [InlineData("profile", true)]
    [InlineData("done", true)]
    [InlineData("billing", false)]
    [InlineData(null, false)]
    public void Setup_step_is_one_of_the_wizard_steps(string? step, bool valid) =>
        Assert.Equal(valid, IdentityValidators.Validate(new AdvanceSetupRequest(step)).Count == 0);

    [Theory]
    [InlineData("doc@hospital.example", "doctor", true)]
    [InlineData("doc@hospital.example", "tenant_admin", true)]
    [InlineData("not-an-email", "doctor", false)]
    [InlineData("doc@hospital.example", "superuser", false)]
    [InlineData("doc@hospital.example", null, false)]
    [InlineData(null, "doctor", false)]
    public void Add_member(string? email, string? role, bool valid) =>
        Assert.Equal(valid, IdentityValidators.Validate(new AddMemberRequest(email, role, null)).Count == 0);

    [Fact]
    public void Tenant_admin_cannot_be_branch_scoped()
    {
        var errors = IdentityValidators.Validate(new AddMemberRequest("a@hospital.example", "tenant_admin", Guid.NewGuid()));
        Assert.Equal(["branchId"], errors.Keys);
        Assert.Empty(IdentityValidators.Validate(new AddMemberRequest("a@hospital.example", "nurse", Guid.NewGuid())));
    }

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
