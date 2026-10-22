using Hms.Modules.Appointments;
using Hms.Modules.Identity;
using Hms.Modules.Patients;
using Hms.Modules.Patients.Endpoints;
using Hms.Platform.Hosting;

// In-memory composition for unit tests. It is not a service, not an image, and not deployed.
// Production hosts are the three services behind the edge. This process does not register the
// email worker or the outbox dispatcher (those need Postgres and stay on their owning service).
var builder = WebApplication.CreateBuilder(args);

builder.AddHmsServiceDefaults("hms-test-host");

builder.Services.AddIdentityModule(builder.Configuration);
builder.Services.AddPatientsModule(builder.Configuration);
builder.Services.AddAppointmentsModule(builder.Configuration);

var app = builder.Build();

app.UseHmsServiceDefaults();

var v1 = app.MapGroup("/api/v1");
v1.MapIdentityEndpoints();
v1.MapPatientEndpoints();
v1.MapAppointmentsModule();

app.Run();

/// <summary>Exposed for WebApplicationFactory-based unit tests.</summary>
public partial class Program;
