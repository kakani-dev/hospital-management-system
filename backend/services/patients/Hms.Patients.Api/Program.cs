using Hms.Modules.Patients;
using Hms.Modules.Patients.Endpoints;
using Hms.Platform.Hosting;
using Hms.Platform.Messaging;

// Patients service: /patients (list, search, duplicates, get, create, patch, delete, restore, merge).
// The edge routes /api/v1/patients here. This service dispatches patient outbox rows.
// Keep Outbox:Dispatcher:Enabled=false (B1). DryRun defaults to true.
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsServiceDefaults("hms-patients");
builder.Services.AddPatientsModule(builder.Configuration);
builder.Services.AddHmsOutboxDispatcher(builder.Configuration);

var app = builder.Build();
app.UseHmsServiceDefaults();
app.MapGroup("/api/v1").MapPatientEndpoints();
app.Run();
