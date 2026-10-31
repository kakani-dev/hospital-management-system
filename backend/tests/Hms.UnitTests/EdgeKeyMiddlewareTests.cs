using Hms.Platform.Http;
using Microsoft.Extensions.Primitives;

namespace Hms.UnitTests;

/// <summary>Issue #68: services accept Edge:Key and, during a rotation, Edge:PreviousKey.</summary>
public class EdgeKeyMiddlewareTests
{
    private static readonly string[] RepeatedHeader = ["new", "old"];

    [Fact]
    public void Current_key_only_when_previous_is_unset()
    {
        var keys = EdgeKeyMiddleware.AcceptedKeys("new", null);
        Assert.Single(keys);
        Assert.True(EdgeKeyMiddleware.Matches(new StringValues("new"), keys));
        Assert.False(EdgeKeyMiddleware.Matches(new StringValues("old"), keys));
    }

    [Fact]
    public void Previous_key_is_accepted_during_rotation()
    {
        var keys = EdgeKeyMiddleware.AcceptedKeys("new", "old");
        Assert.Equal(2, keys.Count);
        Assert.True(EdgeKeyMiddleware.Matches(new StringValues("new"), keys));
        Assert.True(EdgeKeyMiddleware.Matches(new StringValues("old"), keys));
        Assert.False(EdgeKeyMiddleware.Matches(new StringValues("other"), keys));
    }

    [Theory]
    [InlineData("")]
    [InlineData("new")]
    public void Empty_or_equal_previous_key_is_retired(string previous)
    {
        var keys = EdgeKeyMiddleware.AcceptedKeys("new", previous);
        Assert.Single(keys);
        Assert.False(EdgeKeyMiddleware.Matches(new StringValues("old"), keys));
    }

    [Fact]
    public void Missing_empty_or_repeated_header_is_rejected()
    {
        var keys = EdgeKeyMiddleware.AcceptedKeys("new", "old");
        Assert.False(EdgeKeyMiddleware.Matches(StringValues.Empty, keys));
        Assert.False(EdgeKeyMiddleware.Matches(new StringValues(string.Empty), keys));
        Assert.False(EdgeKeyMiddleware.Matches(new StringValues(RepeatedHeader), keys));
    }
}
