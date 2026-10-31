using Hms.Modules.Appointments.Endpoints;
using Hms.Modules.Appointments.Reminders;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Hms.UnitTests;

/// <summary>#59: reminders only ever reach configured synthetic test recipients.</summary>
public sealed class AppointmentRemindersTests
{
    private static DueReminder Due(string channel, string? recipient, string kind = "lead") => new(
        Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), kind, channel, recipient, "Zz-QA Asha", "Dr. Zz-QA Rao", "Demo Hospital",
        DateTimeOffset.UtcNow.AddDays(1), "Asia/Kolkata", 1);

    [Theory]
    [InlineData(null, "Off")]
    [InlineData("", "Off")]
    [InlineData("Live", "Off")]
    [InlineData("testrecipientsonly", "TestRecipientsOnly")]
    public void Unknown_modes_fail_closed(string? mode, string expected) =>
        Assert.Equal(expected, new ReminderOptions { Mode = mode! }.DeliveryMode.ToString());

    [Fact]
    public void Allowlist_matches_case_insensitive_email_and_phone_digits()
    {
        string[] list = ["QA.Reminder@example.test", "+91 90000 00001"];
        Assert.True(ReminderText.IsTestRecipient("qa.reminder@EXAMPLE.test", list));
        Assert.True(ReminderText.IsTestRecipient("+919000000001", list));
        Assert.False(ReminderText.IsTestRecipient("someone@example.test", list));
        Assert.False(ReminderText.IsTestRecipient("", list));
        Assert.False(ReminderText.IsTestRecipient("qa.reminder@example.test", []));
    }

    [Fact]
    public void Masking_hides_most_of_the_recipient()
    {
        Assert.Equal("qa***@example.test", ReminderText.Mask("qa.reminder@example.test"));
        Assert.EndsWith("0001", ReminderText.Mask("+919000000001"));
        Assert.DoesNotContain("90000", ReminderText.Mask("+919000000001"));
    }

    [Fact]
    public void Body_uses_branch_local_time_and_kind()
    {
        var start = new DateTimeOffset(DateTime.UtcNow.Date.AddDays(1).AddHours(4), TimeSpan.Zero); // 09:30 IST
        var lead = ReminderText.Body(Due("email", "x@example.test") with { StartsAt = start });
        Assert.Contains("9:30 AM", lead);
        Assert.Contains("Dr. Zz-QA Rao", lead);
        Assert.Contains("today", ReminderText.Body(Due("email", "x@example.test", "same_day") with { StartsAt = start }));
    }

    [Fact]
    public void Settings_validation_rejects_bad_windows()
    {
        var errors = ReminderEndpoints.Validate(new UpdateReminderSettingsRequest(true, 2, 3, 120, true, false, "21:00", "08:00"), out _, out _);
        Assert.Contains("sameDayHours", errors.Keys);
        Assert.Empty(ReminderEndpoints.Validate(new UpdateReminderSettingsRequest(true, 24, 2, 120, true, false, "21:00", "08:00"), out _, out _));
        Assert.Contains("quietStart", ReminderEndpoints.Validate(new UpdateReminderSettingsRequest(true, 24, 2, 120, true, false, "9pm", "08:00"), out _, out _).Keys);
    }

    [Fact]
    public async Task Sweep_sends_only_to_test_recipients_and_records_every_outcome()
    {
        var store = new FakeStore(
            Due("email", "qa.reminder@example.test"),
            Due("email", "real.person@example.test"),
            Due("whatsapp", "+919000000001"),
            Due("email", "qa.broken@example.test"));
        var email = new FakeChannel("email", true) { FailFor = "qa.broken@example.test" };
        var whatsapp = new FakeChannel("whatsapp", false);
        var options = Options.Create(new ReminderOptions
        {
            Mode = "TestRecipientsOnly",
            TestRecipients = ["qa.reminder@example.test", "+919000000001", "qa.broken@example.test"],
        });
        var sweep = new ReminderSweep(store, [email, whatsapp], options, NullLogger<ReminderSweep>.Instance);

        Assert.Equal(1, await sweep.RunAsync(CancellationToken.None));
        Assert.Equal(["qa.reminder@example.test"], email.Sent);
        Assert.Equal(["sent", "skipped", "skipped", "failed"], store.Completed.Select(c => c.Status));
        Assert.Equal(ReminderSweep.NotTestRecipient, store.Completed[1].Detail);
        Assert.Contains("not configured", store.Completed[2].Detail);
        Assert.DoesNotContain("smtp", store.Completed[3].Detail, StringComparison.OrdinalIgnoreCase);
        Assert.All(store.Completed, c => Assert.Contains("***", c.Masked));
    }

    [Fact]
    public async Task Sweep_does_nothing_when_off()
    {
        var store = new FakeStore(Due("email", "qa.reminder@example.test"));
        var sweep = new ReminderSweep(store, [], Options.Create(new ReminderOptions()), NullLogger<ReminderSweep>.Instance);
        Assert.Equal(0, await sweep.RunAsync(CancellationToken.None));
        Assert.False(store.Claimed);
    }

    private sealed class FakeStore(params DueReminder[] due) : IReminderStore
    {
        public bool Claimed { get; private set; }
        public List<(string Status, string Detail, string Masked)> Completed { get; } = [];

        public Task<IReadOnlyList<DueReminder>> ClaimAsync(int limit, CancellationToken ct)
        {
            Claimed = true;
            return Task.FromResult<IReadOnlyList<DueReminder>>(due);
        }

        public Task CompleteAsync(Guid id, string status, string detail, string recipientMasked, CancellationToken ct)
        {
            Completed.Add((status, detail, recipientMasked));
            return Task.CompletedTask;
        }
    }

    private sealed class FakeChannel(string channel, bool configured) : IReminderChannel
    {
        public string? FailFor { get; init; }
        public List<string> Sent { get; } = [];
        public string Channel => channel;
        public bool IsConfigured => configured;

        public Task SendAsync(string recipient, string subject, string body, CancellationToken ct)
        {
            if (recipient == FailFor)
            {
                throw new TimeoutException("smtp.example.test:587 timed out");
            }

            Sent.Add(recipient);
            return Task.CompletedTask;
        }
    }
}
