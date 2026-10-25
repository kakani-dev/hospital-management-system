using Hms.Modules.Identity;
using Hms.Modules.Identity.Email;
using Hms.Modules.Identity.Endpoints;
using Hms.Platform.Hosting;
using Hms.Platform.Messaging;

// Identity service: /me, /me/context, /me/invitations, /tenants/current, /branches, /members,
// plus the platform console (/platform/**) and the public hospital registration (/public/**),
// which only this service hosts (code review MIN-5).
// Product mail is queued on messaging.outbox and sent by the email worker (hms_mailer).
// Tenant events are claimed here. Both workers stay off until their own flags are set (B1).
// The domain dispatcher never claims email_message rows.
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsServiceDefaults("hms-identity");
builder.Services.AddIdentityModule(builder.Configuration);
builder.Services.AddPlatformEndpoints(builder.Configuration);
builder.Services.AddHmsOutboxDispatcher(builder.Configuration);
builder.Services.AddIdentityEmailDelivery(builder.Configuration);

var app = builder.Build();
app.UseHmsServiceDefaults();
app.MapGroup("/api/v1").MapIdentityEndpoints().MapPlatformEndpoints();
app.Run();
