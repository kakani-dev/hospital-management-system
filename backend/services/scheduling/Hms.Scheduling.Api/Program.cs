using Hms.Modules.Appointments;
using Hms.Modules.Appointments.Endpoints;
using Hms.Platform.Hosting;
using Hms.Platform.Messaging;

// Scheduling service: /practitioners, /schedules, /slots, /appointments, /queue, and the outbox
// dispatcher (it owns the appointment/queue events). Branch membership, day overrides, the travel
// buffer and my-day (/practitioner-branches, /schedule-overrides, /scheduling-settings,
// /practitioners/me/day) are mapped here only — the legacy monolith calls MapAppointmentsModule
// and does not serve them. Keep Outbox:Dispatcher:Enabled=false while the monolith still
// dispatches (SKIP LOCKED makes overlap safe, but one owner is clearer).
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsServiceDefaults("hms-scheduling");
builder.Services.AddAppointmentsModule(builder.Configuration);
builder.Services.AddHmsOutboxDispatcher(builder.Configuration);

var app = builder.Build();
app.UseHmsServiceDefaults();
app.MapGroup("/api/v1").MapAppointmentsModule().MapPractitionerBranchEndpoints();
app.Run();
