namespace Hms.Platform.Http;

public static class SecurityHeadersMiddleware
{
    public static IApplicationBuilder UseHmsSecurityHeaders(this IApplicationBuilder app) =>
        app.Use(async (context, next) =>
        {
            var headers = context.Response.Headers;
            headers["X-Content-Type-Options"] = "nosniff";
            headers["X-Frame-Options"] = "DENY";
            headers["Referrer-Policy"] = "no-referrer";
            headers["Cache-Control"] = context.Request.Path.StartsWithSegments("/api") ? "no-store" : headers.CacheControl.ToString();
            await next();
        });
}
