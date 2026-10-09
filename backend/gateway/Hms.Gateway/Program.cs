using Hms.Modules.Appointments;
using Hms.Modules.Identity;
using Hms.Modules.Patients;
using Hms.Modules.Patients.Endpoints;
using Hms.Platform.Hosting;
using Hms.Platform.Messaging;

// Legacy all-in-one host (the modular monolith): every module in one process. It stays the
// deployed API until the YARP edge routes each prefix to its own service (MICROSERVICES-PLAN.md §12).
var builder = WebApplication.CreateBuilder(args);

builder.AddHmsServiceDefaults("hms-gateway");

// ---- Modules (each owns its schema, endpoints and DbContext)
builder.Services.AddIdentityModule(builder.Configuration);
builder.Services.AddPatientsModule(builder.Configuration);
builder.Services.AddAppointmentsModule(builder.Configuration);

// ---- Transactional outbox consumer (events are written by DB triggers; Sprint 2 publisher = log only)
builder.Services.AddHmsOutboxDispatcher(builder.Configuration);

var app = builder.Build();

app.UseHmsServiceDefaults();

var v1 = app.MapGroup("/api/v1");
v1.MapIdentityEndpoints();
v1.MapPatientEndpoints();
v1.MapAppointmentsModule();

app.Run();

/// <summary>Exposed for WebApplicationFactory-based integration tests.</summary>
public partial class Program;
