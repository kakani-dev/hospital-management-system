using System.Threading.RateLimiting;
using Hms.Gateway.Infrastructure;
using Hms.Modules.Identity;
using Hms.Modules.Patients;
using Hms.Modules.Patients.Endpoints;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.HttpOverrides;
using Serilog;
using Serilog.Formatting.Compact;

var builder = WebApplication.CreateBuilder(args);

// ---- Structured logging (JSON to stdout). Never log request bodies: they may contain PHI.
builder.Services.AddSerilog((services, lc) => lc
    .ReadFrom.Configuration(builder.Configuration)
    .ReadFrom.Services(services)
    .Enrich.FromLogContext()
    .Enrich.WithProperty("Application", "hms-gateway")
    .WriteTo.Console(new RenderedCompactJsonFormatter()));

builder.Services.AddProblemDetails();
builder.Services.AddOpenApi("v1");

builder.Services.AddHmsAuthentication(builder.Configuration, builder.Environment);
builder.Services.AddHmsHealthChecks();

// ---- Modules (each owns its schema, endpoints and DbContext)
builder.Services.AddIdentityModule(builder.Configuration);
builder.Services.AddPatientsModule(builder.Configuration);

// ---- Rate limiting: per authenticated user, else per client IP.
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(ctx =>
        RateLimitPartition.GetFixedWindowLimiter(
            ctx.User.FindFirst("sub")?.Value ?? ctx.Connection.RemoteIpAddress?.ToString() ?? "anonymous",
            _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = builder.Configuration.GetValue("RateLimiting:PermitPerMinute", 120),
                Window = TimeSpan.FromMinutes(1),
                QueueLimit = 0,
            }));
});

var allowedOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
builder.Services.AddCors(o => o.AddDefaultPolicy(p => p
    .WithOrigins(allowedOrigins)
    .WithMethods("GET", "POST", "PUT", "PATCH", "DELETE")
    .WithHeaders("Authorization", "Content-Type", "apikey", "x-client-info")
    // Let the SPA read the resolved tenant (M3 option b); custom headers are hidden from JS otherwise.
    .WithExposedHeaders(HmsHeaders.Tenant)));

builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    // TODO(Sprint 4): restrict KnownProxies/KnownNetworks to the Render proxy range.
});

var app = builder.Build();

app.UseForwardedHeaders();
app.UseExceptionHandler();
app.UseStatusCodePages();
app.UseHmsSecurityHeaders();
app.UseSerilogRequestLogging();

if (app.Configuration.GetValue("OpenApi:Enabled", app.Environment.IsDevelopment()))
{
    app.MapOpenApi();
    app.UseSwaggerUI(o =>
    {
        o.SwaggerEndpoint("/openapi/v1.json", "HMS API v1");
        o.RoutePrefix = "swagger";
    });
}

app.UseCors();
app.UseAuthentication();
// Throttle BEFORE tenant resolution: resolution costs 1-2 DB transactions per request and the
// partition key only needs the validated "sub" claim (review Minor 2).
app.UseRateLimiter();
app.UseTenantResolution(); // derives tenant from validated claims + DB membership; sets X-Hms-Tenant
app.UseAuthorization();

app.MapHmsHealthChecks();

var v1 = app.MapGroup("/api/v1");
v1.MapIdentityEndpoints();
v1.MapPatientEndpoints();

app.Run();

/// <summary>Exposed for WebApplicationFactory-based integration tests.</summary>
public partial class Program;
