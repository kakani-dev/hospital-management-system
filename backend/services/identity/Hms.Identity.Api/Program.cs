using Hms.Modules.Identity;
using Hms.Platform.Hosting;

// Identity service: /me, /me/context, /me/invitations, /tenants/current, /branches, /members.
// Phase 0 skeleton: built, containerised and health-checked, but receives no production traffic
// until the YARP edge routes these prefixes here (MICROSERVICES-PLAN.md §12, Phase 4).
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsServiceDefaults("hms-identity");
builder.Services.AddIdentityModule(builder.Configuration);

var app = builder.Build();
app.UseHmsServiceDefaults();
app.MapGroup("/api/v1").MapIdentityEndpoints();
app.Run();
