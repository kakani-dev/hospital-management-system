using Hms.Modules.Privacy;
using Hms.Platform.Hosting;

// Privacy service: DPDP notices, consent, and data-principal requests.
// The edge routes /api/v1/privacy here. Minimal APIs, same shape as the other services.
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsServiceDefaults("hms-privacy");
builder.Services.AddPrivacyModule(builder.Configuration);

var app = builder.Build();
app.UseHmsServiceDefaults();
app.MapGroup("/api/v1").MapPrivacyModule();
app.Run();
