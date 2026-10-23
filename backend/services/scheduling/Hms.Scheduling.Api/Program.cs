using Hms.Modules.Appointments;
using Hms.Modules.Appointments.Endpoints;
using Hms.Platform.Hosting;
using Hms.Platform.Messaging;

// Scheduling service: /practitioners, /schedules, /slots, /appointments, /queue,
// /practitioner-branches, /schedule-overrides, /scheduling-settings, /practitioners/me/day,
// and the outbox dispatcher (it owns the appointment/queue events). The edge routes these
// prefixes here. Keep Outbox:Dispatcher:Enabled=false (B1). hms_svc_scheduling is not hms_dispatcher.
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsServiceDefaults("hms-scheduling");
builder.Services.AddAppointmentsModule(builder.Configuration);
builder.Services.AddHmsOutboxDispatcher(builder.Configuration);

var app = builder.Build();
app.UseHmsServiceDefaults();
app.MapGroup("/api/v1").MapAppointmentsModule().MapPractitionerBranchEndpoints();
app.Run();
