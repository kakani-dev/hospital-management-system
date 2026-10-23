using Hms.Modules.Billing;
using Hms.Platform.Hosting;

// Billing service: OP bills, receipts, approvals, counters and the public receipt / UPI webhook.
// It publishes messaging.outbox rows and does not dispatch them (the dispatcher stays on scheduling, off).
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsServiceDefaults("hms-billing");
builder.Services.AddBillingModule(builder.Configuration);

var app = builder.Build();
app.UseHmsServiceDefaults();
app.MapGroup("/api/v1").MapBillingModule();
app.Run();
