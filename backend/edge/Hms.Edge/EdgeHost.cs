using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.RateLimiting;
using Hms.Platform.Auth;
using Hms.Platform.Http;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.RateLimiting;
using Serilog;
using Serilog.Formatting.Compact;
using Yarp.ReverseProxy.Forwarder;
using Yarp.ReverseProxy.Transforms;

namespace Hms.Edge;

/// <summary>Service registration and pipeline of the edge (kept out of Program.cs so tests can reuse pieces).</summary>
public static partial class EdgeHost
{
    public const string UpstreamHttpClient = "hms-upstream";
    public const string WarmupPolicy = "warmup";
    public const string CorsPolicy = "hms-web";

    /// <summary>Response headers the SPA must be able to read cross-origin.</summary>
    public static readonly string[] ExposedHeaders = ["X-Hms-Tenant", RequestIdMiddleware.Header, "Retry-After"];

    public static WebApplicationBuilder AddHmsEdge(this WebApplicationBuilder builder)
    {
        ArgumentNullException.ThrowIfNull(builder);
        var services = builder.Services;
        var configuration = builder.Configuration;

        services.AddSerilog((sp, lc) => lc
            .ReadFrom.Configuration(configuration)
            .ReadFrom.Services(sp)
            .Enrich.FromLogContext()
            .Enrich.WithProperty("Application", "hms-edge")
            .WriteTo.Console(new RenderedCompactJsonFormatter()));
        services.AddProblemDetails();

        // JWT pre-validation with the same rules as every service (services re-validate; the edge only
        // rejects early and partitions the rate limit by user). JWKS outage -> 503, not 401.
        services.AddHmsAuthentication(configuration, builder.Environment);

        services.AddCors(o => o.AddPolicy(CorsPolicy, p => p
            .SetIsOriginAllowed(EdgeCors.Allowed(configuration))
            .WithMethods("GET", "POST", "PUT", "PATCH", "DELETE")
            .WithHeaders("Authorization", "Content-Type", "apikey", "x-client-info", RequestIdMiddleware.Header, "traceparent")
            .WithExposedHeaders(ExposedHeaders)
            .SetPreflightMaxAge(TimeSpan.FromSeconds(configuration.GetValue("Cors:PreflightMaxAgeSeconds", 600)))));

        services.AddRateLimiter(options =>
        {
            options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(ctx =>
                ctx.Request.Path.StartsWithSegments("/health")
                    ? RateLimitPartition.GetNoLimiter("health")
                    : RateLimitPartition.GetFixedWindowLimiter(
                        ctx.User.FindFirst("sub")?.Value ?? ctx.Connection.RemoteIpAddress?.ToString() ?? "anonymous",
                        _ => new FixedWindowRateLimiterOptions
                        {
                            PermitLimit = configuration.GetValue("RateLimiting:PermitPerMinute", 300),
                            Window = TimeSpan.FromMinutes(1),
                            QueueLimit = 0,
                        }));
            options.AddPolicy(WarmupPolicy, ctx => RateLimitPartition.GetFixedWindowLimiter(
                ctx.Connection.RemoteIpAddress?.ToString() ?? "anonymous",
                _ => new FixedWindowRateLimiterOptions
                {
                    PermitLimit = configuration.GetValue("RateLimiting:WarmupPerMinute", 10),
                    Window = TimeSpan.FromMinutes(1),
                    QueueLimit = 0,
                }));
            options.OnRejected = async (context, ct) =>
            {
                var retryAfter = context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var ra) ? (int)Math.Ceiling(ra.TotalSeconds) : 60;
                var response = context.HttpContext.Response;
                response.StatusCode = StatusCodes.Status429TooManyRequests;
                response.Headers.RetryAfter = Math.Max(retryAfter, 1).ToString(CultureInfo.InvariantCulture);
                response.ContentType = "application/problem+json";
                await response.WriteAsync(JsonSerializer.Serialize(new
                {
                    type = "https://tools.ietf.org/html/rfc6585#section-4",
                    title = "Too many requests",
                    status = 429,
                    detail = "Too many requests. Retry after the indicated delay.",
                    code = "rate_limited",
                    traceId = context.HttpContext.TraceIdentifier,
                }, JsonSerializerOptions.Web), ct).ConfigureAwait(false);
            };
        });

        services.Configure<ForwardedHeadersOptions>(o =>
        {
            o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
            // TODO(Phase 1): restrict KnownProxies/KnownNetworks to the Container Apps ingress range.
        });

        services.AddHttpClient(UpstreamHttpClient);
        services.AddSingleton<UpstreamProbe>();

        var edgeKey = configuration[EdgeKeyMiddleware.ConfigKey];
        services.AddReverseProxy()
            .LoadFromConfig(configuration.GetSection("ReverseProxy"))
            .AddTransforms(t => t.AddRequestTransform(ctx =>
            {
                // The tenant and every other X-Hms-* value come from the token + DB inside the service,
                // never from the client: strip them all, then add the edge key and the correlation id.
                var headers = ctx.ProxyRequest.Headers;
                foreach (var name in headers.Select(h => h.Key).Where(IsHmsHeader).ToList())
                {
                    headers.Remove(name);
                }

                if (!string.IsNullOrEmpty(edgeKey))
                {
                    headers.TryAddWithoutValidation(EdgeKeyMiddleware.Header, edgeKey);
                }

                headers.Remove(RequestIdMiddleware.Header);
                headers.TryAddWithoutValidation(RequestIdMiddleware.Header, ctx.HttpContext.TraceIdentifier);
                return ValueTask.CompletedTask;
            }));

        return builder;
    }

    public static WebApplication UseHmsEdge(this WebApplication app)
    {
        ArgumentNullException.ThrowIfNull(app);
        app.UseForwardedHeaders();
        app.UseHmsRequestId();
        app.Use(SecurityHeadersAsync);
        app.Use(BlockInternalAsync);
        // CORS before everything that can answer on its own (401, 429, 5xx, 503), so the browser can read
        // those responses instead of seeing an opaque network error.
        app.UseCors(CorsPolicy);
        app.UseExceptionHandler(e => e.Run(ctx => ServiceUnavailable.WriteAsync(
            ctx, "The gateway hit an unexpected error. Retry shortly.", StatusCodes.Status500InternalServerError, "edge_error")));
        app.UseSerilogRequestLogging();
        app.UseAuthentication();
        app.UseRateLimiter();
        app.UseAuthorization();

        app.MapGet("/health/live", () => Results.Json(new { status = "Healthy" })).AllowAnonymous();
        app.MapGet("/health/ready", async (UpstreamProbe probe, HttpContext ctx) =>
            await probe.WriteAsync(ctx, TimeSpan.FromSeconds(10))).AllowAnonymous();
        app.MapGet("/api/v1/warmup", async (UpstreamProbe probe, HttpContext ctx) =>
            await probe.WriteAsync(ctx, TimeSpan.FromSeconds(25)))
            .AllowAnonymous().RequireRateLimiting(WarmupPolicy);

        app.MapReverseProxy(proxy => proxy.Use(async (context, next) =>
        {
            await next().ConfigureAwait(false);
            var error = context.GetForwarderErrorFeature();
            if (error is null || context.Response.HasStarted)
            {
                return;
            }

            if (error.Error is ForwarderError.RequestTimedOut)
            {
                await ServiceUnavailable.WriteAsync(context, "The service did not answer in time. Retry shortly.",
                    StatusCodes.Status504GatewayTimeout, ServiceUnavailable.UpstreamTimeoutCode).ConfigureAwait(false);
            }
            else if (error.Error is not (ForwarderError.RequestCanceled or ForwarderError.RequestBodyCanceled))
            {
                await ServiceUnavailable.WriteAsync(context, "The service is starting or unreachable. Retry shortly.").ConfigureAwait(false);
            }
        }));

        // Anything else under /api/v1 has no owning service: 404 problem (not a proxy to nowhere).
        app.MapFallback("/api/v1/{**rest}", (HttpContext ctx) => Results.Problem(
            statusCode: StatusCodes.Status404NotFound, title: "Not found", detail: "No such API route.",
            extensions: new Dictionary<string, object?> { ["code"] = "not_found", ["traceId"] = ctx.TraceIdentifier }))
            .AllowAnonymous();
        return app;
    }

    public static bool IsHmsHeader(string name) => name.StartsWith("X-Hms-", StringComparison.OrdinalIgnoreCase);

    private static Task SecurityHeadersAsync(HttpContext context, RequestDelegate next)
    {
        // OnStarting runs after YARP copied the upstream headers, so these overwrite (never duplicate) them.
        context.Response.OnStarting(() =>
        {
            var headers = context.Response.Headers;
            headers["X-Content-Type-Options"] = "nosniff";
            headers["X-Frame-Options"] = "DENY";
            headers["Referrer-Policy"] = "no-referrer";
            headers.Remove("Server");
            if (context.Request.Path.StartsWithSegments("/api"))
            {
                headers.CacheControl = "no-store";
            }

            return Task.CompletedTask;
        });
        return next(context);
    }

    /// <summary>
    /// <c>/internal/**</c> (service-to-service endpoints such as event push) is never reachable from
    /// outside: any method, any case, any percent-encoding or backslash variant -> 404.
    /// </summary>
    private static Task BlockInternalAsync(HttpContext context, RequestDelegate next)
    {
        var raw = context.Features.Get<Microsoft.AspNetCore.Http.Features.IHttpRequestFeature>()?.RawTarget ?? string.Empty;
        if (IsInternalPath(context.Request.Path.Value) || IsInternalPath(raw))
        {
            context.Response.StatusCode = StatusCodes.Status404NotFound;
            return Task.CompletedTask;
        }

        return next(context);
    }

    public static bool IsInternalPath(string? path)
    {
        if (string.IsNullOrEmpty(path))
        {
            return false;
        }

        var q = path.IndexOfAny(['?', '#']);
        var value = q >= 0 ? path[..q] : path;
        for (var i = 0; i < 3; i++) // %252F-style double encoding
        {
            var decoded = Uri.UnescapeDataString(value);
            if (decoded == value)
            {
                break;
            }

            value = decoded;
        }

        return PathSeparators().Split(value).Any(s => s.Trim().TrimEnd('.').Equals("internal", StringComparison.OrdinalIgnoreCase));
    }

    [GeneratedRegex(@"[/\\;]+", RegexOptions.CultureInvariant)]
    private static partial Regex PathSeparators();
}
