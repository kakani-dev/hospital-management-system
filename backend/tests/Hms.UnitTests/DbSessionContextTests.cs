using System.Text.Json;
using Hms.SharedKernel.Persistence;

namespace Hms.UnitTests;

public class DbSessionContextTests
{
    private static readonly Guid User = Guid.Parse("0a000000-0000-4000-8000-000000000001");
    private static readonly Guid Tenant = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid Branch = Guid.Parse("a1111111-0000-4000-8000-000000000001");

    [Fact]
    public void Anonymous_session_maps_to_anon_role_only()
    {
        var session = new DbSessionContext();
        Assert.False(session.IsAuthenticated);
        Assert.Equal("{\"role\":\"anon\"}", session.ToClaimsJson());
    }

    [Fact]
    public void Authenticated_session_carries_sub_role_audience_and_tenant()
    {
        var session = new DbSessionContext();
        session.SetUser(User, "admin@alpha.example");
        session.SetTenant(Tenant, Branch);

        using var json = JsonDocument.Parse(session.ToClaimsJson());
        var root = json.RootElement;
        Assert.Equal(User.ToString(), root.GetProperty("sub").GetString());
        Assert.Equal("authenticated", root.GetProperty("role").GetString());
        Assert.Equal("authenticated", root.GetProperty("aud").GetString());
        Assert.Equal("admin@alpha.example", root.GetProperty("email").GetString());
        Assert.Equal(Tenant.ToString(), root.GetProperty("tenant_id").GetString());
        Assert.Equal(Branch.ToString(), root.GetProperty("branch_id").GetString());
    }

    [Fact]
    public void User_without_tenant_omits_tenant_claims()
    {
        var session = new DbSessionContext();
        session.SetUser(User, null);
        using var json = JsonDocument.Parse(session.ToClaimsJson());
        Assert.False(json.RootElement.TryGetProperty("tenant_id", out _));
        Assert.False(json.RootElement.TryGetProperty("branch_id", out _));
        Assert.False(json.RootElement.TryGetProperty("email", out _));
    }

    [Fact]
    public void Tenant_cannot_be_pinned_before_the_user()
    {
        var session = new DbSessionContext();
        Assert.Throws<InvalidOperationException>(() => session.SetTenant(Tenant, null));
    }

    [Fact]
    public void Empty_user_id_is_rejected()
    {
        var session = new DbSessionContext();
        Assert.Throws<ArgumentException>(() => session.SetUser(Guid.Empty, null));
    }

    [Fact]
    public void Session_role_is_a_postgres_identifier_or_the_authenticated_default()
    {
        Assert.Equal("authenticated", new DatabaseSessionOptions(null).AuthenticatedRole);
        Assert.Equal("authenticated", new DatabaseSessionOptions("  ").AuthenticatedRole);
        Assert.Equal("hms_svc_patients", new DatabaseSessionOptions(" hms_svc_patients ").AuthenticatedRole);
        Assert.Throws<ArgumentException>(() => new DatabaseSessionOptions("authenticated; select 1"));
        Assert.Throws<ArgumentException>(() => new DatabaseSessionOptions("Hms_Svc"));
    }

    [Fact]
    public void Claims_json_escapes_hostile_email_values()
    {
        var session = new DbSessionContext();
        session.SetUser(User, "x\",\"role\":\"service_role");
        using var json = JsonDocument.Parse(session.ToClaimsJson());
        Assert.Equal("authenticated", json.RootElement.GetProperty("role").GetString());
    }
}
