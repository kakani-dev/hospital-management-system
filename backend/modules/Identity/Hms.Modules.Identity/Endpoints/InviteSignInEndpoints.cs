using Hms.Modules.Identity.Email;
using Hms.Platform.Http;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.HttpResults;
using Npgsql;

namespace Hms.Modules.Identity.Endpoints;

public sealed record InviteSignInCodeIssuedDto(DateTimeOffset ExpiresOn);

public sealed record InviteSignInRequest(string? Code);

public sealed record InviteSignInProofDto(string TokenHash, string VerificationType);

public static partial class PlatformEndpoints
{
    private static async Task<Results<Accepted<InviteSignInCodeIssuedDto>, NotFound, ProblemHttpResult>> RequestInviteSignInCodeAsync(
        string token, IInviteSignInStore store, IPasswordlessSessionIssuer issuer, CancellationToken cancellationToken)
    {
        if (!TokenPattern().IsMatch(token))
        {
            return TypedResults.NotFound();
        }

        if (!issuer.IsConfigured)
        {
            return SignInNotConfigured();
        }

        try
        {
            var expires = await store.IssueAsync(token, cancellationToken);
            return TypedResults.Accepted((string?)null, new InviteSignInCodeIssuedDto(expires));
        }
        catch (PostgresException ex) when (ex.SqlState == "P0002")
        {
            return TypedResults.NotFound();
        }
        catch (PostgresException ex) when (ex.SqlState == "54000")
        {
            return TypedResults.Problem(
                title: "Too many requests",
                detail: "Too many sign-in codes were sent. Try again later.",
                statusCode: StatusCodes.Status429TooManyRequests,
                extensions: new Dictionary<string, object?> { ["code"] = "rate_limited" });
        }
    }

    private static async Task<Results<Ok<InviteSignInProofDto>, NotFound, UnauthorizedHttpResult, ProblemHttpResult>> ExchangeInviteSignInCodeAsync(
        string token, InviteSignInRequest request, IInviteSignInStore store, IPasswordlessSessionIssuer issuer, CancellationToken cancellationToken)
    {
        if (!TokenPattern().IsMatch(token))
        {
            return TypedResults.NotFound();
        }

        if (request.Code is not { Length: 6 } code || code.Any(c => c is < '0' or > '9'))
        {
            return TypedResults.Unauthorized();
        }

        if (!issuer.IsConfigured)
        {
            return SignInNotConfigured();
        }

        string email;
        try
        {
            email = await store.ConsumeAsync(token, request.Code, cancellationToken);
        }
        catch (PostgresException ex) when (ex.SqlState == "P0002")
        {
            return TypedResults.NotFound();
        }
        catch (PostgresException ex) when (ex.SqlState == "42501")
        {
            return TypedResults.Unauthorized();
        }
        catch (InviteSignInRejectedException)
        {
            return TypedResults.Unauthorized();
        }

        try
        {
            var proof = await issuer.CreateAsync(email, cancellationToken);
            return TypedResults.Ok(new InviteSignInProofDto(proof.TokenHash, proof.VerificationType));
        }
        catch (InvalidOperationException)
        {
            return TypedResults.Problem(
                title: "Sign-in unavailable",
                detail: "The code was accepted but sign-in could not be completed. Request a new code.",
                statusCode: StatusCodes.Status503ServiceUnavailable);
        }
    }

    private static ProblemHttpResult SignInNotConfigured() =>
        TypedResults.Problem(
            title: "Sign-in unavailable",
            detail: "Email sign-in is not configured.",
            statusCode: StatusCodes.Status503ServiceUnavailable);
}
