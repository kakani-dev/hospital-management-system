using Hms.Modules.Patients;
using Hms.Modules.Patients.Endpoints;
using Hms.Platform.Hosting;

// Patients service: /patients (list, search, duplicates, get, create, patch, delete, restore, merge).
// The edge routes /api/v1/patients here.
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsServiceDefaults("hms-patients");
builder.Services.AddPatientsModule(builder.Configuration);

var app = builder.Build();
app.UseHmsServiceDefaults();
app.MapGroup("/api/v1").MapPatientEndpoints();
app.Run();
