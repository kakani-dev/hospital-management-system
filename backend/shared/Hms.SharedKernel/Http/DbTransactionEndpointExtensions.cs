using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Routing;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Metadata;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Hms.SharedKernel.Http;

public static class DbTransactionEndpointExtensions
{
    /// <summary>
    /// Runs the endpoint inside one database transaction on <typeparamref name="TContext"/>.
    /// The RLS interceptor fires when the transaction starts, so every query in the endpoint is
    /// subject to PostgreSQL RLS as the calling user. Commits on 2xx/3xx, rolls back otherwise.
    /// </summary>
    public static RouteGroupBuilder WithDbTransaction<TContext>(this RouteGroupBuilder builder)
        where TContext : DbContext
    {
        Add<TContext>(builder);
        return builder;
    }

    /// <inheritdoc cref="WithDbTransaction{TContext}(RouteGroupBuilder)"/>
    public static RouteHandlerBuilder WithDbTransaction<TContext>(this RouteHandlerBuilder builder)
        where TContext : DbContext
    {
        Add<TContext>(builder);
        return builder;
    }

    private static void Add<TContext>(IEndpointConventionBuilder builder)
        where TContext : DbContext
    {
        builder.AddEndpointFilter(async (context, next) =>
        {
            var db = context.HttpContext.RequestServices.GetRequiredService<TContext>();
            if (!db.Database.IsRelational())
            {
                return await next(context);
            }

            var ct = context.HttpContext.RequestAborted;
            await using var tx = await db.Database.BeginTransactionAsync(ct);
            var result = await next(context);
            if (StatusOf(result) < 400)
            {
                await tx.CommitAsync(ct);
            }
            else
            {
                await tx.RollbackAsync(ct);
            }

            return result;
        });
    }

    private static int StatusOf(object? result) => result switch
    {
        INestedHttpResult nested => StatusOf(nested.Result),
        IStatusCodeHttpResult { StatusCode: { } code } => code,
        _ => StatusCodes.Status200OK,
    };
}
