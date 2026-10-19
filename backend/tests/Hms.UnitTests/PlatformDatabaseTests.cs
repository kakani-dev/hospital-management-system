using Hms.Platform.Persistence;
using Microsoft.Extensions.Configuration;
using Npgsql;

namespace Hms.UnitTests;

public class PlatformDatabaseTests
{
    private static NpgsqlConnectionStringBuilder Parse(string cs) => new(cs);

    private static IConfiguration Config(string? connection, string? maxPool = null) =>
        new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["ConnectionStrings:HmsDatabase"] = connection,
            [HmsDatabase.MaxPoolSizeKey] = maxPool,
        }).Build();

    [Fact]
    public void No_reset_on_close_is_forced_in_code_for_the_supavisor_pooler()
    {
        var cs = HmsDatabase.ConnectionString(Config("Host=db;Port=6543;Database=postgres;Username=u;Password=p"));
        Assert.True(Parse(cs).NoResetOnClose);
        Assert.Equal(6543, Parse(cs).Port);
    }

    [Theory]
    [InlineData("Host=db;No Reset On Close=false")]
    [InlineData("Host=db;noresetonclose=false")]
    public void An_explicit_no_reset_on_close_setting_is_respected(string raw) =>
        Assert.False(Parse(HmsDatabase.ConnectionString(Config(raw))).NoResetOnClose);

    [Fact]
    public void Max_pool_size_is_configurable_per_service()
    {
        Assert.Equal(10, Parse(HmsDatabase.ConnectionString(Config("Host=db", "10"))).MaxPoolSize);
        Assert.Equal(new NpgsqlConnectionStringBuilder().MaxPoolSize, Parse(HmsDatabase.ConnectionString(Config("Host=db"))).MaxPoolSize);
    }

    [Fact]
    public void Missing_connection_string_is_empty_not_an_exception() =>
        Assert.Equal(string.Empty, HmsDatabase.ConnectionString(Config(null)));
}
