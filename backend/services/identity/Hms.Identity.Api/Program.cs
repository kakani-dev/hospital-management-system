using Hms.Modules.Identity;
using Hms.Modules.Identity.Email;
using Hms.Modules.Identity.Endpoints;
using Hms.Platform.Hosting;

// Identity service: /me, /me/context, /me/invitations, /tenants/current, /branches, /members,
// plus the platform console (/platform/**) and the public hospital registration (/public/**),
// which only this service hosts (not the legacy monolith, code review MIN-5).
// Product mail is queued on messaging.outbox and sent here. Do not register the scheduling
// outbox dispatcher: tenant events are a log, and the legacy host stays off (B1).
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsServiceDefaults("hms-identity");
builder.Services.AddIdentityModule(builder.Configuration);
builder.Services.AddPlatformEndpoints(builder.Configuration);
builder.Services.AddIdentityEmailDelivery(builder.Configuration);

var app = builder.Build();
app.UseHmsServiceDefaults();
app.MapGroup("/api/v1").MapIdentityEndpoints().MapPlatformEndpoints();
app.Run();
