using Hms.Modules.Identity.Domain;
using Hms.Modules.Identity.Persistence;
using Hms.Modules.Patients.Domain;
using Hms.Modules.Patients.Persistence;
using Hms.SharedKernel.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hms.IntegrationTests;

/// <summary>Gateway host with in-memory databases seeded with two SYNTHETIC tenants.</summary>
public sealed class HmsApiFactory : WebApplicationFactory<Program>
{
    public static readonly Guid Alpha = Guid.Parse("11111111-1111-4111-8111-111111111111");
    public static readonly Guid Beta = Guid.Parse("22222222-2222-4222-8222-222222222222");
    public static readonly Guid AlphaMain = Guid.Parse("a1111111-0000-4000-8000-000000000001");
    public static readonly Guid AlphaEast = Guid.Parse("a1111111-0000-4000-8000-000000000002");
    public static readonly Guid BetaMain = Guid.Parse("b2222222-0000-4000-8000-000000000001");
    public static readonly Guid AlphaAdmin = Guid.Parse("0a000000-0000-4000-8000-000000000001");
    public static readonly Guid AlphaReception = Guid.Parse("0a000000-0000-4000-8000-000000000002");
    public static readonly Guid AlphaLab = Guid.Parse("0a000000-0000-4000-8000-000000000003");
    public static readonly Guid BetaDoctor = Guid.Parse("0b000000-0000-4000-8000-000000000002");
    public static readonly Guid BetaPatientId = Guid.Parse("bb000000-0000-4000-8000-000000000001");

    private readonly string _dbName = $"hms-tests-{Guid.NewGuid()}";

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.UseSetting("RateLimiting:PermitPerMinute", "10000");
        builder.ConfigureServices(services =>
        {
            ReplaceWithInMemory<IdentityDbContext>(services, (_, o) => o.UseInMemoryDatabase(_dbName));
            ReplaceWithInMemory<PatientsDbContext>(services, (sp, o) => o
                .UseInMemoryDatabase(_dbName)
                .AddInterceptors(sp.GetRequiredService<TenantSaveChangesInterceptor>()));

            services.AddAuthentication(TestAuthHandler.SchemeName)
                .AddScheme<AuthenticationSchemeOptions, TestAuthHandler>(TestAuthHandler.SchemeName, _ => { });
            services.PostConfigure<AuthenticationOptions>(o =>
            {
                o.DefaultScheme = TestAuthHandler.SchemeName;
                o.DefaultAuthenticateScheme = TestAuthHandler.SchemeName;
                o.DefaultChallengeScheme = TestAuthHandler.SchemeName;
            });
        });
    }

    private static void ReplaceWithInMemory<TContext>(IServiceCollection services, Action<IServiceProvider, DbContextOptionsBuilder> configure)
        where TContext : DbContext
    {
        services.RemoveAll<DbContextOptions<TContext>>();
        services.RemoveAll<IDbContextOptionsConfiguration<TContext>>();
        services.AddDbContext<TContext>(configure);
    }

    public void Seed()
    {
        using var scope = Services.CreateScope();
        var identity = scope.ServiceProvider.GetRequiredService<IdentityDbContext>();
        if (identity.Tenants.Any())
        {
            return;
        }

        identity.Tenants.AddRange(
            new Tenant { Id = Alpha, Code = "demo-alpha", Name = "Demo Alpha Hospital (synthetic)" },
            new Tenant { Id = Beta, Code = "demo-beta", Name = "Demo Beta Clinic (synthetic)" });
        identity.Branches.AddRange(
            new Branch { Id = AlphaMain, TenantId = Alpha, Code = "main", Name = "Alpha Main Campus" },
            new Branch { Id = AlphaEast, TenantId = Alpha, Code = "east", Name = "Alpha East Clinic" },
            new Branch { Id = BetaMain, TenantId = Beta, Code = "main", Name = "Beta Central" });
        identity.Memberships.AddRange(
            new Membership { TenantId = Alpha, UserId = AlphaAdmin, Role = HmsRoles.TenantAdmin },
            new Membership { TenantId = Alpha, UserId = AlphaReception, BranchId = AlphaMain, Role = HmsRoles.Receptionist },
            new Membership { TenantId = Alpha, UserId = AlphaLab, Role = HmsRoles.LabTechnician },
            new Membership { TenantId = Beta, UserId = BetaDoctor, Role = HmsRoles.Doctor });
        identity.SaveChanges();

        // Seed patients bypassing the interceptor (raw in-memory context without tenant context).
        var options = new DbContextOptionsBuilder<PatientsDbContext>().UseInMemoryDatabase(_dbName).Options;
        var alphaCtx = new TenantContext();
        alphaCtx.Resolve(Alpha, AlphaAdmin, null, [HmsRoles.TenantAdmin], [AlphaMain]);
        using var patients = new PatientsDbContext(options, alphaCtx);
        patients.Patients.AddRange(
            new Patient { TenantId = Alpha, RegisteredBranchId = AlphaMain, Mrn = "ALP-0001", FirstName = "Asha", LastName = "Synthetic-Alpha", Sex = PatientSex.Female },
            new Patient { TenantId = Alpha, RegisteredBranchId = AlphaMain, Mrn = "MRN-1001", FirstName = "Kiran", LastName = "Synthetic-Alpha" },
            new Patient { Id = BetaPatientId, TenantId = Beta, RegisteredBranchId = BetaMain, Mrn = "MRN-1001", FirstName = "Kiran", LastName = "Synthetic-Beta" });
        patients.SaveChanges();
    }
}
