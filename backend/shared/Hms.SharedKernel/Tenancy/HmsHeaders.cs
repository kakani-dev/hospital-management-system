namespace Hms.SharedKernel.Tenancy;

/// <summary>Custom HTTP headers that are part of the public API contract.</summary>
public static class HmsHeaders
{
    /// <summary>
    /// Response header carrying the tenant id the server resolved for this request. Present on
    /// every response to an authenticated request with a resolved tenant. Clients compare it with
    /// the tenant they display and reset their state on mismatch (review M3, option b).
    /// </summary>
    public const string Tenant = "X-Hms-Tenant";
}
