using System.Xml.Linq;

namespace Hms.UnitTests;

/// <summary>
/// Service boundaries as a test (MICROSERVICES-PLAN.md §7-§8): which project may reference which.
/// Reads the csproj files, so a new ProjectReference across a boundary fails CI.
/// </summary>
public class ArchitectureTests
{
    private static readonly string Backend = FindBackend();

    private static string FindBackend()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "Hms.slnx")))
            {
                return dir.FullName;
            }
        }

        throw new InvalidOperationException("backend/Hms.slnx not found above the test output directory.");
    }

    private static List<string> References(string relativeCsproj)
    {
        var path = Path.Combine(Backend, relativeCsproj);
        return XDocument.Load(path).Descendants("ProjectReference")
            .Select(r => Path.GetFileNameWithoutExtension(r.Attribute("Include")!.Value.Replace('\\', '/')))
            .Order(StringComparer.Ordinal)
            .ToList();
    }

    [Fact]
    public void Shared_kernel_references_nothing() =>
        Assert.Empty(References("shared/Hms.SharedKernel/Hms.SharedKernel.csproj"));

    [Fact]
    public void Platform_references_only_the_shared_kernel() =>
        Assert.Equal(["Hms.SharedKernel"], References("platform/Hms.Platform/Hms.Platform.csproj"));

    [Theory]
    [InlineData("modules/Identity/Hms.Modules.Identity/Hms.Modules.Identity.csproj")]
    [InlineData("modules/Patients/Hms.Modules.Patients/Hms.Modules.Patients.csproj")]
    [InlineData("modules/Appointments/Hms.Modules.Appointments/Hms.Modules.Appointments.csproj")]
    [InlineData("modules/Billing/Hms.Modules.Billing/Hms.Modules.Billing.csproj")]
    [InlineData("modules/Inventory/Hms.Modules.Inventory/Hms.Modules.Inventory.csproj")]
    [InlineData("modules/Privacy/Hms.Modules.Privacy/Hms.Modules.Privacy.csproj")]
    public void Modules_never_reference_another_module(string csproj) =>
        Assert.Equal(["Hms.Platform", "Hms.SharedKernel"], References(csproj));

    [Theory]
    [InlineData("services/identity/Hms.Identity.Api/Hms.Identity.Api.csproj", "Hms.Modules.Identity")]
    [InlineData("services/patients/Hms.Patients.Api/Hms.Patients.Api.csproj", "Hms.Modules.Patients")]
    [InlineData("services/scheduling/Hms.Scheduling.Api/Hms.Scheduling.Api.csproj", "Hms.Modules.Appointments")]
    [InlineData("services/billing/Hms.Billing.Api/Hms.Billing.Api.csproj", "Hms.Modules.Billing")]
    [InlineData("services/inventory/Hms.Inventory.Api/Hms.Inventory.Api.csproj", "Hms.Modules.Inventory")]
    [InlineData("services/privacy/Hms.Privacy.Api/Hms.Privacy.Api.csproj", "Hms.Modules.Privacy")]
    public void Each_service_hosts_exactly_its_own_module(string csproj, string module) =>
        Assert.Equal(new[] { module, "Hms.Platform" }.Order(StringComparer.Ordinal), References(csproj));

    [Fact]
    public void Edge_references_only_the_platform_never_a_module() =>
        Assert.Equal(["Hms.Platform"], References("edge/Hms.Edge/Hms.Edge.csproj"));

    [Fact]
    public void Email_worker_stays_on_identity_and_the_outbox_dispatcher_stays_on_owning_services()
    {
        var identity = File.ReadAllText(Path.Combine(Backend, "services", "identity", "Hms.Identity.Api", "Program.cs"));
        var patients = File.ReadAllText(Path.Combine(Backend, "services", "patients", "Hms.Patients.Api", "Program.cs"));
        var scheduling = File.ReadAllText(Path.Combine(Backend, "services", "scheduling", "Hms.Scheduling.Api", "Program.cs"));
        var billing = File.ReadAllText(Path.Combine(Backend, "services", "billing", "Hms.Billing.Api", "Program.cs"));
        var inventory = File.ReadAllText(Path.Combine(Backend, "services", "inventory", "Hms.Inventory.Api", "Program.cs"));
        var privacy = File.ReadAllText(Path.Combine(Backend, "services", "privacy", "Hms.Privacy.Api", "Program.cs"));
        var edge = File.ReadAllText(Path.Combine(Backend, "edge", "Hms.Edge", "Program.cs"));
        Assert.Contains("AddIdentityEmailDelivery", identity, StringComparison.Ordinal);
        Assert.DoesNotContain("AddIdentityEmailDelivery", patients, StringComparison.Ordinal);
        Assert.DoesNotContain("AddIdentityEmailDelivery", scheduling, StringComparison.Ordinal);
        Assert.DoesNotContain("AddIdentityEmailDelivery", billing, StringComparison.Ordinal);
        Assert.DoesNotContain("AddIdentityEmailDelivery", inventory, StringComparison.Ordinal);
        Assert.DoesNotContain("AddIdentityEmailDelivery", privacy, StringComparison.Ordinal);
        Assert.Contains("AddHmsOutboxDispatcher", identity, StringComparison.Ordinal);
        Assert.Contains("AddHmsOutboxDispatcher", patients, StringComparison.Ordinal);
        Assert.Contains("AddHmsOutboxDispatcher", scheduling, StringComparison.Ordinal);
        Assert.Contains("AddHmsOutboxDispatcher", billing, StringComparison.Ordinal);
        Assert.DoesNotContain("AddHmsOutboxDispatcher", inventory, StringComparison.Ordinal);
        Assert.DoesNotContain("AddHmsOutboxDispatcher", privacy, StringComparison.Ordinal);
        Assert.DoesNotContain("AddHmsOutboxDispatcher", edge, StringComparison.Ordinal);
    }

    [Fact]
    public void No_production_host_references_more_than_one_module()
    {
        var sep = Path.DirectorySeparatorChar;
        var hosts = Directory.EnumerateFiles(Backend, "*.csproj", SearchOption.AllDirectories)
            .Where(p => !p.Contains($"{sep}tests{sep}", StringComparison.Ordinal)
                        && !p.Contains($"{sep}bin{sep}", StringComparison.Ordinal)
                        && !p.Contains($"{sep}obj{sep}", StringComparison.Ordinal))
            .Select(p => Path.GetRelativePath(Backend, p))
            .Where(p => References(p).Count(r => r.StartsWith("Hms.Modules.", StringComparison.Ordinal)) > 1)
            .ToList();
        Assert.Empty(hosts);
    }
}
