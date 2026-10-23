using System.Threading.RateLimiting;
using Hms.Platform.Auth;
using Hms.Platform.Health;
using Hms.Platform.Http;
using Hms.Platform.Tenancy;
using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Serilog;
using Serilog.Formatting.Compact;

namespace Hms.Platform.Hosting;

/// <summary>
/// The standard HMS service host (MICROSERVICES-PLAN.md §7): every service calls
/// <see cref="AddHmsServiceDefaults"/> + <see cref="UseHmsServiceDefaults"/> and then only adds
/// its own module and endpoints. The middleware ORDER here is the Sprint 1/2 order and is
/// security-relevant; change it only with Code Review.
/// </summary>
public static class ServiceDefaults
{
    public static WebApplicationBuilder AddHmsServiceDefaults(this WebApplicationBuilder builder, string applicationName)
    {
        ArgumentNullException.ThrowIfNull(builder);
        var services = builder.Services;
        var configuration = builder.Configuration;

        // ---- Structured logging (JSON to stdout). Never log request bodies: they may contain PHI.
        services.AddSerilog((sp, lc) => lc
            .ReadFrom.Configuration(configuration)
            .ReadFrom.Services(sp)
            .Enrich.FromLogContext()
            .Enrich.WithProperty("Application", applicationName)
            .WriteTo.Console(new RenderedCompactJsonFormatter()));

        services.AddProblemDetails();
        services.AddOpenApi("v1");

        services.AddHmsAuthentication(configuration, builder.Environment);
        services.AddHmsTenancy(configuration);
        services.AddHmsHealthChecks();

        // ---- Rate limiting: per authenticated user, else per client IP.
        services.AddRateLimiter(options =>
        {
            options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
            options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(ctx =>
                RateLimitPartition.GetFixedWindowLimiter(
                    ctx.User.FindFirst("sub")?.Value ?? ctx.Connection.RemoteIpAddress?.ToString() ?? "anonymous",
                    _ => new FixedWindowRateLimiterOptions
                    {
                        PermitLimit = configuration.GetValue("RateLimiting:PermitPerMinute", 120),
                        Window = TimeSpan.FromMinutes(1),
                        QueueLimit = 0,
                    }));
        });

        var allowedOrigins = configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
        services.AddCors(o => o.AddDefaultPolicy(p => p
            .WithOrigins(allowedOrigins)
            .WithMethods("GET", "POST", "PUT", "PATCH", "DELETE")
            .WithHeaders("Authorization", "Content-Type", "apikey", "x-client-info")
            // Let the SPA read the resolved tenant (M3 option b); custom headers are hidden from JS otherwise.
            .WithExposedHeaders(HmsHeaders.Tenant)));

        services.Configure<ForwardedHeadersOptions>(o =>
        {
            o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
            // TODO(Sprint 4): restrict KnownProxies/KnownNetworks to the platform proxy range.
        });

        return builder;
    }

    /// <summary>Pipeline up to (and including) authorization + health endpoints. Map the API after this.</summary>
    public static WebApplication UseHmsServiceDefaults(this WebApplication app)
    {
        ArgumentNullException.ThrowIfNull(app);
        app.UseForwardedHeaders();
        app.UseHmsEdgeKey(app.Configuration); // 404 unless the request came through the edge (when Edge:Key is set)
        app.UseHmsRequestId();
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
        return app;
    }
}
