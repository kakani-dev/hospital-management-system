using System.Diagnostics;
using System.Text.Json;
using Hms.Platform.Http;
using Yarp.ReverseProxy;

namespace Hms.Edge;

/// <summary>
/// Readiness of every service behind the edge: GET {destination}/health/ready on each cluster in
/// parallel. Used by the edge's own <c>/health/ready</c> (aggregate: all services must be ready) and by
/// the anonymous, rate-limited <c>/api/v1/warmup</c> that the web app calls once after sign-in to wake
/// scale-to-zero services. 200 when all are ready, otherwise 503 + Retry-After (service_unavailable).
/// </summary>
public sealed class UpstreamProbe(IProxyStateLookup proxyState, IHttpClientFactory httpClientFactory, IConfiguration configuration)
{
    public async Task WriteAsync(HttpContext context, TimeSpan timeout)
    {
        ArgumentNullException.ThrowIfNull(context);
        var results = await ProbeAllAsync(timeout, context.RequestAborted).ConfigureAwait(false);
        var ready = results.Count > 0 && results.TrueForAll(r => r.Ready);
        if (!ready)
        {
            context.Response.Headers.RetryAfter = ServiceUnavailable.RetryAfterSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        context.Response.StatusCode = ready ? StatusCodes.Status200OK : StatusCodes.Status503ServiceUnavailable;
        context.Response.Headers.CacheControl = "no-store";
        context.Response.ContentType = "application/json";
        await context.Response.WriteAsync(JsonSerializer.Serialize(new
        {
            status = ready ? "Healthy" : "Unhealthy",
            code = ready ? null : ServiceUnavailable.Code,
            services = results.Select(r => new { name = r.Name, status = r.Ready ? "Healthy" : "Unhealthy", durationMs = r.DurationMs }),
        }, JsonSerializerOptions.Web), context.RequestAborted).ConfigureAwait(false);
    }

    public async Task<List<ProbeResult>> ProbeAllAsync(TimeSpan timeout, CancellationToken ct)
    {
        var client = httpClientFactory.CreateClient(EdgeHost.UpstreamHttpClient);
        var edgeKey = configuration[EdgeKeyMiddleware.ConfigKey];
        var tasks = proxyState.GetClusters()
            .SelectMany(c => c.Destinations.Values.Take(1).Select(d => (Cluster: c.ClusterId, Address: d.Model.Config.Address)))
            .Select(async t =>
            {
                var sw = Stopwatch.StartNew();
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(timeout);
                try
                {
                    using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(new Uri(t.Address), "health/ready"));
                    if (!string.IsNullOrEmpty(edgeKey))
                    {
                        request.Headers.TryAddWithoutValidation(EdgeKeyMiddleware.Header, edgeKey);
                    }

                    using var response = await client.SendAsync(request, cts.Token).ConfigureAwait(false);
                    return new ProbeResult(t.Cluster, response.IsSuccessStatusCode, Math.Round(sw.Elapsed.TotalMilliseconds, 1));
                }
#pragma warning disable CA1031 // any failure (refused, DNS, timeout) just means "not ready yet"
                catch (Exception)
#pragma warning restore CA1031
                {
                    return new ProbeResult(t.Cluster, false, Math.Round(sw.Elapsed.TotalMilliseconds, 1));
                }
            });
        return [.. (await Task.WhenAll(tasks).ConfigureAwait(false)).OrderBy(r => r.Name, StringComparer.Ordinal)];
    }

    public sealed record ProbeResult(string Name, bool Ready, double DurationMs);
}
