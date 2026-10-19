using Hms.Edge;

// MediCore HMS edge (YARP API gateway). Browser -> edge -> exactly one service; the web app keeps a
// single base URL (VITE_API_BASE_URL) and the same /api/v1/* paths. See docs/architecture/microservices.md.
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsEdge();

var app = builder.Build();
app.UseHmsEdge();
app.Run();
