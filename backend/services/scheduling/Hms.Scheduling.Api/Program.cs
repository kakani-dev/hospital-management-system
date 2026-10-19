using Hms.Modules.Appointments;
using Hms.Platform.Hosting;
using Hms.Platform.Messaging;

// Scheduling service: /practitioners, /schedules, /slots, /appointments, /queue, and the outbox
// dispatcher (it owns the appointment/queue events). Phase 0 skeleton: built, containerised and
// health-checked, but receives no production traffic until the YARP edge routes these prefixes
// here (MICROSERVICES-PLAN.md §12, Phase 3). Keep Outbox:Dispatcher:Enabled=false while the
// monolith still dispatches (SKIP LOCKED makes overlap safe, but one owner is clearer).
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsServiceDefaults("hms-scheduling");
builder.Services.AddAppointmentsModule(builder.Configuration);
builder.Services.AddHmsOutboxDispatcher(builder.Configuration);

var app = builder.Build();
app.UseHmsServiceDefaults();
app.MapGroup("/api/v1").MapAppointmentsModule();
app.Run();
