using Hms.Modules.Billing;
using Hms.Platform.Hosting;
using Hms.Platform.Messaging;

// Billing service: OP bills, receipts, approvals, counters and the public receipt / UPI webhook.
// It publishes billing outbox rows and dispatches only those. The flag stays off (B1).
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsServiceDefaults("hms-billing");
builder.Services.AddBillingModule(builder.Configuration);
builder.Services.AddHmsOutboxDispatcher(builder.Configuration);

var app = builder.Build();
app.UseHmsServiceDefaults();
app.MapGroup("/api/v1").MapBillingModule();
app.Run();
