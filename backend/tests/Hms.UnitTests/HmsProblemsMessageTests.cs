using Hms.Platform.Http;

namespace Hms.UnitTests;

/// <summary>#149: which database messages a 404 or 409 may show to the caller.</summary>
public class HmsProblemsMessageTests
{
    [Theory]
    [InlineData("branch is not deleted", "Branch is not deleted; there is nothing to restore.")]
    [InlineData("patient is not deleted", "Patient is not deleted; there is nothing to restore.")]
    [InlineData("invite not found, expired or already used", "Invite not found, expired or already used.")]
    public void Safe_not_found_messages_are_shown(string db, string shown) =>
        Assert.Equal(shown, HmsProblems.SafeNotFoundDetail(db));

    [Theory]
    [InlineData("no auth user with that email; the person must sign up first")] // would reveal account existence
    [InlineData("patient not found")]
    [InlineData("query returned no rows")]
    [InlineData("")]
    [InlineData(null)]
    public void Other_not_found_messages_stay_generic(string? db) =>
        Assert.Null(HmsProblems.SafeNotFoundDetail(db));
}
