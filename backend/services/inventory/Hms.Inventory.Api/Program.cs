using Hms.Modules.Inventory;
using Hms.Platform.Hosting;

// Inventory service: item master, stores, opening stock, and stock on hand.
// The edge routes /api/v1/inventory here.
var builder = WebApplication.CreateBuilder(args);
builder.AddHmsServiceDefaults("hms-inventory");
builder.Services.AddInventoryModule(builder.Configuration);

var app = builder.Build();
app.UseHmsServiceDefaults();
app.MapGroup("/api/v1").MapInventoryModule();
app.Run();
