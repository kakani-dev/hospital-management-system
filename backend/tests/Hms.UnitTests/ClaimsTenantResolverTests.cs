using System.Security.Claims;
using Hms.Platform.Tenancy;

namespace Hms.UnitTests;

public class ClaimsTenantResolverTests
{
    private static readonly Guid User = Guid.Parse("0a000000-0000-4000-8000-000000000001");
    private static readonly Guid Tenant = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid Branch = Guid.Parse("a1111111-0000-4000-8000-000000000001");

    private static ClaimsPrincipal Principal(params (string Type, string Value)[] claims) =>
        new(new ClaimsIdentity(claims.Select(c => new Claim(c.Type, c.Value)), authenticationType: "Bearer"));

    [Fact]
    public void Unauthenticated_principal_fails()
    {
        var anonymous = new ClaimsPrincipal(new ClaimsIdentity([new Claim("tenant_id", Tenant.ToString())]));
        Assert.Equal("unauthenticated", ClaimsTenantResolver.Resolve(anonymous).Failure);
        Assert.Equal("unauthenticated", ClaimsTenantResolver.Resolve(null).Failure);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("not-a-guid")]
    [InlineData("00000000-0000-0000-0000-000000000000")]
    public void Missing_or_invalid_subject_fails(string? sub)
    {
        var claims = new List<(string, string)> { ("tenant_id", Tenant.ToString()) };
        if (sub is not null)
        {
            claims.Add(("sub", sub));
        }

        Assert.Equal("missing_or_invalid_subject", ClaimsTenantResolver.Resolve(Principal([.. claims])).Failure);
    }

    [Fact]
    public void Missing_tenant_claim_fails()
    {
        var result = ClaimsTenantResolver.Resolve(Principal(("sub", User.ToString())));
        Assert.False(result.Succeeded);
        Assert.Equal("missing_tenant_claim", result.Failure);
    }

    [Fact]
    public void Invalid_tenant_claim_fails()
    {
        var result = ClaimsTenantResolver.Resolve(Principal(("sub", User.ToString()), ("tenant_id", "alpha")));
        Assert.Equal("invalid_tenant_claim", result.Failure);
    }

    [Fact]
    public void Top_level_claims_resolve()
    {
        var result = ClaimsTenantResolver.Resolve(Principal(("sub", User.ToString()), ("tenant_id", Tenant.ToString()), ("branch_id", Branch.ToString())));
        Assert.True(result.Succeeded);
        Assert.Equal(new TenantClaims(User, Tenant, Branch), result.Claims);
    }

    [Fact]
    public void Supabase_app_metadata_json_resolves()
    {
        var appMetadata = $$"""{"provider":"email","tenant_id":"{{Tenant}}","branch_id":"{{Branch}}"}""";
        var result = ClaimsTenantResolver.Resolve(Principal(("sub", User.ToString()), ("app_metadata", appMetadata)));
        Assert.True(result.Succeeded);
        Assert.Equal(Tenant, result.Claims!.TenantId);
        Assert.Equal(Branch, result.Claims.BranchId);
    }

    [Fact]
    public void User_metadata_is_ignored_because_users_can_edit_it()
    {
        var userMetadata = $$"""{"tenant_id":"{{Tenant}}"}""";
        var result = ClaimsTenantResolver.Resolve(Principal(("sub", User.ToString()), ("user_metadata", userMetadata)));
        Assert.Equal("missing_tenant_claim", result.Failure);
    }

    [Fact]
    public void Malformed_app_metadata_is_treated_as_missing()
    {
        var result = ClaimsTenantResolver.Resolve(Principal(("sub", User.ToString()), ("app_metadata", "{not json")));
        Assert.Equal("missing_tenant_claim", result.Failure);
    }

    [Fact]
    public void Invalid_branch_claim_fails()
    {
        var result = ClaimsTenantResolver.Resolve(Principal(("sub", User.ToString()), ("tenant_id", Tenant.ToString()), ("branch_id", "east")));
        Assert.Equal("invalid_branch_claim", result.Failure);
    }

    [Fact]
    public void Branch_is_optional()
    {
        var result = ClaimsTenantResolver.Resolve(Principal(("sub", User.ToString()), ("tenant_id", Tenant.ToString())));
        Assert.True(result.Succeeded);
        Assert.Null(result.Claims!.BranchId);
    }
}
