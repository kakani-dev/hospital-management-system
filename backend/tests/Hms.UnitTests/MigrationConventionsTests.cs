using System.Text.RegularExpressions;

namespace Hms.UnitTests;

/// <summary>
/// Static checks on the AUDIT-TZ migrations (files from 20261012090000 on): hosted-safe locking
/// (code review MIN-4) and the published cross-schema surface header (DB re-review N5).
/// </summary>
public partial class MigrationConventionsTests
{
    private static string MigrationsDir()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "supabase", "migrations");
            if (Directory.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new DirectoryNotFoundException("supabase/migrations not found above the test binaries.");
    }

    public static TheoryData<string> AuditTzMigrations()
    {
        var data = new TheoryData<string>();
        foreach (var file in Directory.GetFiles(MigrationsDir(), "*.sql").Order(StringComparer.Ordinal))
        {
            if (string.CompareOrdinal(Path.GetFileName(file), "20261012090000") >= 0)
            {
                data.Add(Path.GetFileName(file));
            }
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(AuditTzMigrations))]
    public void Migration_sets_a_lock_timeout_and_statement_timeout(string file)
    {
        var sql = File.ReadAllText(Path.Combine(MigrationsDir(), file));
        Assert.Matches(LockTimeout(), sql);
        Assert.Matches(StatementTimeout(), sql);
    }

    [Theory]
    [MemberData(nameof(AuditTzMigrations))]
    public void Every_published_v1_function_carries_the_cross_schema_header(string file)
    {
        var lines = File.ReadAllLines(Path.Combine(MigrationsDir(), file));
        for (var i = 0; i < lines.Length; i++)
        {
            if (V1Definition().IsMatch(lines[i]))
            {
                Assert.True(i > 0 && lines[i - 1].StartsWith("-- cross-schema: approved", StringComparison.Ordinal),
                    $"{file}:{i + 1} defines a *_v1 function without a '-- cross-schema: approved' header line");
            }
        }
    }

    [GeneratedRegex(@"(?m)^set local lock_timeout = '\d+s';")]
    private static partial Regex LockTimeout();

    [GeneratedRegex(@"(?m)^set local statement_timeout = '\d+s';")]
    private static partial Regex StatementTimeout();

    // published read functions; change_time_zone_v1 / assert_zone_change_allowed_v1 are identity commands
    [GeneratedRegex(@"^create or replace function \w+\.(?!change_time_zone_v1|assert_zone_change_allowed_v1)\w+_v1\(")]
    private static partial Regex V1Definition();
}
