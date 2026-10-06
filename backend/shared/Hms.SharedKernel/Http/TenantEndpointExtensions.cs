using Hms.SharedKernel.Tenancy;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;

namespace Hms.SharedKernel.Http;

public static class TenantEndpointExtensions
{
    /// <summary>
    /// Requires an authenticated user AND a tenant context resolved from validated claims +
    /// active membership. Returns 403 problem details otherwise.
    /// </summary>
    public static TBuilder RequireTenant<TBuilder>(this TBuilder builder)
        where TBuilder : IEndpointConventionBuilder
    {
        builder.RequireAuthorization();
        builder.AddEndpointFilter(async (context, next) =>
        {
            var tenant = context.HttpContext.RequestServices.GetRequiredService<ITenantContext>();
            if (!tenant.IsResolved)
            {
                return Results.Problem(
                    title: "No active tenant membership",
                    detail: "The authenticated user has no active membership for the tenant in their token.",
                    statusCode: StatusCodes.Status403Forbidden);
            }

            return await next(context);
        });
        return builder;
    }
}
