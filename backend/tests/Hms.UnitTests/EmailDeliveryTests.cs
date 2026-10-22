using System.Net;
using System.Text.Json;
using Hms.Modules.Identity.Email;
using Hms.Platform.Auth;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Hms.UnitTests;

public sealed class EmailTemplateTests
{
    private const string Token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    [Fact]
    public void Links_use_the_configured_base_url_and_html_is_encoded()
    {
        using var document = JsonDocument.Parse(
            $$"""{"hospitalName":"Ward <script>","role":"nurse","token":"{{Token}}","expiresOn":"2026-11-01T00:00:00Z"}""");
        var rendered = EmailTemplates.Render("invite_link", document.RootElement, "https://links.example.test/hms/");

        Assert.Contains("https://links.example.test/hms/invite/" + Token, rendered.TextBody, StringComparison.Ordinal);
        Assert.Contains("https://links.example.test/hms/invite/" + Token, rendered.HtmlBody, StringComparison.Ordinal);
        Assert.DoesNotContain("medicore-hms-three.vercel.app", rendered.HtmlBody, StringComparison.Ordinal);
        Assert.Contains("Ward &lt;script&gt;", rendered.HtmlBody, StringComparison.Ordinal);
        Assert.DoesNotContain("<script>", rendered.HtmlBody, StringComparison.Ordinal);
        Assert.Contains("nurse", rendered.TextBody, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("signup_received")]
    [InlineData("signup_approved")]
    [InlineData("signup_rejected")]
    public void Each_product_template_has_text_and_html(string template)
    {
        var json = template switch
        {
            "signup_approved" => $$"""{"hospitalName":"Synthetic Hospital","contactName":"Asha","role":"tenant_admin","token":"{{Token}}","expiresOn":"2026-12-01T00:00:00+00:00"}""",
            "signup_rejected" => """{"hospitalName":"Synthetic Hospital","contactName":"Asha","reason":"Not a hospital"}""",
            _ => """{"hospitalName":"Synthetic Hospital","contactName":"Asha"}""",
        };
        using var document = JsonDocument.Parse(json);
        var rendered = EmailTemplates.Render(template, document.RootElement, "https://links.example.test");

        Assert.False(string.IsNullOrWhiteSpace(rendered.Subject));
        Assert.Contains("Synthetic Hospital", rendered.TextBody, StringComparison.Ordinal);
        Assert.Contains("Synthetic Hospital", rendered.HtmlBody, StringComparison.Ordinal);
        Assert.Contains("<!DOCTYPE html>", rendered.HtmlBody, StringComparison.Ordinal);
        if (template == "signup_approved")
        {
            Assert.Contains("https://links.example.test/invite/" + Token, rendered.TextBody, StringComparison.Ordinal);
        }

        if (template == "signup_rejected")
        {
            Assert.Contains("Not a hospital", rendered.TextBody, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void A_sign_in_code_email_contains_the_code_and_a_fragment_link()
    {
        using var document = JsonDocument.Parse(
            $$"""{"hospitalName":"Synthetic Hospital","code":"123456","token":"{{Token}}","expiresOn":"2026-11-01T00:10:00Z"}""");
        var rendered = EmailTemplates.Render("sign_in_code", document.RootElement, "https://links.example.test");
        Assert.Contains("123456", rendered.TextBody, StringComparison.Ordinal);
        Assert.Contains("https://links.example.test/invite/" + Token + "#code=123456", rendered.TextBody, StringComparison.Ordinal);
        Assert.Contains("https://links.example.test/invite/" + Token + "#code=123456", rendered.HtmlBody, StringComparison.Ordinal);
        Assert.DoesNotContain("password is", rendered.TextBody, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void A_bad_sign_in_code_is_refused_without_echoing_it()
    {
        using var document = JsonDocument.Parse(
            $$"""{"hospitalName":"H","code":"12-ABC","token":"{{Token}}","expiresOn":"soon"}""");
        var error = Assert.Throws<InvalidOperationException>(() => EmailTemplates.Render("sign_in_code", document.RootElement, "https://links.example.test"));
        Assert.DoesNotContain("12-ABC", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void A_bad_token_is_refused_without_echoing_it()
    {
        using var document = JsonDocument.Parse("""{"hospitalName":"H","role":"nurse","token":"not-a-token","expiresOn":"soon"}""");
        var error = Assert.Throws<InvalidOperationException>(() => EmailTemplates.Render("invite_link", document.RootElement, "https://links.example.test"));
        Assert.DoesNotContain("not-a-token", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void A_base_url_with_credentials_is_refused()
    {
        using var document = JsonDocument.Parse(
            $$"""{"hospitalName":"H","role":"nurse","token":"{{Token}}","expiresOn":"2026-11-01T00:00:00Z"}""");
        Assert.Throws<InvalidOperationException>(() => EmailTemplates.Render("invite_link", document.RootElement, "https://user:secret@links.example.test"));
    }
}

public sealed class EmailOutboxDispatcherTests
{
    [Fact]
    public async Task One_email_is_sent_per_event_when_delivery_is_retried()
    {
        var pendingId = Guid.NewGuid();
        var eventId = Guid.NewGuid();
        var message = new EmailOutboxMessage(7, eventId, Guid.NewGuid(), pendingId, "signup_received", 1);
        var store = new FakeOutbox(message);
        var sender = new FlakySender(failTimes: 1);
        var dispatcher = Dispatcher(store, sender);

        await dispatcher.RunOnceAsync(CancellationToken.None);
        Assert.Equal(1, sender.Attempts);
        Assert.Equal(0, sender.Delivered);
        Assert.DoesNotContain(eventId, store.Receipts);
        Assert.Single(store.Failed);

        store.Queue(message with { Attempts = 2 });
        await dispatcher.RunOnceAsync(CancellationToken.None);
        Assert.Equal(1, sender.Delivered);
        Assert.Contains(eventId, store.Receipts);
        Assert.Contains(pendingId, store.Redacted);

        store.Queue(message with { Attempts = 3 });
        await dispatcher.RunOnceAsync(CancellationToken.None);
        Assert.Equal(1, sender.Delivered);
        Assert.Equal(2, sender.Attempts);
        Assert.Equal(2, store.Completed.Count);
    }

    [Fact]
    public async Task A_revoked_invite_is_acknowledged_without_sending()
    {
        var message = new EmailOutboxMessage(3, Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), "invite_link", 1);
        var store = new FakeOutbox(message) { Suppressed = true };
        var sender = new FlakySender(failTimes: 0);
        await Dispatcher(store, sender).RunOnceAsync(CancellationToken.None);

        Assert.Equal(0, sender.Attempts);
        Assert.Equal([3L], store.Completed);
    }

    [Fact]
    public async Task The_daily_cap_leaves_events_pending()
    {
        var store = new FakeOutbox { SendsToday = 400 };
        var sender = new FlakySender(failTimes: 0);
        var handled = await Dispatcher(store, sender, dailyLimit: 400).RunOnceAsync(CancellationToken.None);

        Assert.Equal(0, handled);
        Assert.Equal(0, store.Claims);
        Assert.Equal(0, sender.Attempts);
    }

    [Fact]
    public void Failure_text_does_not_keep_an_email_address()
    {
        var safe = EmailOutboxDispatcher.SafeError(new IOException("smtp timeout talking to nurse@synthetic.example"));
        Assert.DoesNotContain("@", safe, StringComparison.Ordinal);
        Assert.Contains("IOException", safe, StringComparison.Ordinal);
    }

    private static EmailOutboxDispatcher Dispatcher(FakeOutbox store, FlakySender sender, int dailyLimit = 400) =>
        new(store, sender, Options.Create(new EmailDeliveryOptions
        {
            PublicBaseUrl = "https://links.example.test",
            Dispatcher = new EmailDispatcherOptions { DailySendLimit = dailyLimit, RetryBaseSeconds = 1, BatchSize = 10 },
        }), TimeProvider.System, NullLogger<EmailOutboxDispatcher>.Instance);

    private sealed class FlakySender(int failTimes) : IEmailSender
    {
        public int Attempts { get; private set; }

        public int Delivered { get; private set; }

        public Task SendAsync(OutgoingEmail email, CancellationToken cancellationToken)
        {
            Attempts++;
            if (Attempts <= failTimes)
            {
                throw new IOException("smtp timeout");
            }

            Delivered++;
            Assert.Contains("Synthetic Hospital", email.TextBody, StringComparison.Ordinal);
            Assert.False(string.IsNullOrWhiteSpace(email.HtmlBody));
            return Task.CompletedTask;
        }
    }

    private sealed class FakeOutbox : IEmailOutbox
    {
        private readonly Queue<IReadOnlyList<EmailOutboxMessage>> _batches = new();

        public FakeOutbox(params EmailOutboxMessage[] first) => Queue(first);

        public int SendsToday { get; set; }

        public bool Suppressed { get; set; }

        public int Claims { get; private set; }

        public HashSet<Guid> Receipts { get; } = [];

        public HashSet<Guid> Redacted { get; } = [];

        public List<long> Completed { get; } = [];

        public List<string> Failed { get; } = [];

        public void Queue(params EmailOutboxMessage[] messages) => _batches.Enqueue(messages);

        public Task<int> SendsTodayAsync(CancellationToken cancellationToken) => Task.FromResult(SendsToday);

        public Task<IReadOnlyList<EmailOutboxMessage>> ClaimAsync(string workerId, int batchSize, TimeSpan lease, CancellationToken cancellationToken)
        {
            Claims++;
            IReadOnlyList<EmailOutboxMessage> batch = _batches.Count == 0 ? [] : _batches.Dequeue();
            return Task.FromResult(batch);
        }

        public Task<bool> AlreadySentAsync(Guid eventId, CancellationToken cancellationToken) => Task.FromResult(Receipts.Contains(eventId));

        public Task<PendingEmail?> LoadAsync(Guid pendingEmailId, CancellationToken cancellationToken)
        {
            if (Suppressed)
            {
                return Task.FromResult<PendingEmail?>(null);
            }

            using var document = JsonDocument.Parse("""{"hospitalName":"Synthetic Hospital","contactName":"Asha"}""");
            return Task.FromResult<PendingEmail?>(new PendingEmail("signup_received", "asha@synthetic.example", document.RootElement.Clone()));
        }

        public Task<bool> RecordSentAsync(Guid eventId, Guid tenantId, CancellationToken cancellationToken) => Task.FromResult(Receipts.Add(eventId));

        public Task RedactAsync(Guid pendingEmailId, CancellationToken cancellationToken)
        {
            Redacted.Add(pendingEmailId);
            return Task.CompletedTask;
        }

        public Task CompleteAsync(long id, string workerId, CancellationToken cancellationToken)
        {
            Completed.Add(id);
            return Task.CompletedTask;
        }

        public Task FailAsync(long id, string workerId, string failure, TimeSpan retryIn, CancellationToken cancellationToken)
        {
            Failed.Add(failure);
            return Task.CompletedTask;
        }
    }
}

public sealed class SmtpConfigurationTests
{
    [Fact]
    public async Task A_missing_password_fails_before_any_network_call()
    {
        var sender = new SmtpEmailSender(Options.Create(new SmtpOptions()));
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => sender.SendAsync(
            new OutgoingEmail("person@synthetic.example", "Hello", "text", "<p>text</p>"), CancellationToken.None));
        Assert.Equal(SmtpEmailSender.PasswordMissingMessage, error.Message);
        Assert.DoesNotContain("person@", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Appsettings_and_docs_do_not_commit_an_smtp_password()
    {
        var root = FindRepo();
        foreach (var file in Directory.EnumerateFiles(root, "appsettings*.json", SearchOption.AllDirectories))
        {
            using var document = JsonDocument.Parse(File.ReadAllText(file));
            if (document.RootElement.TryGetProperty("Smtp", out var smtp) && smtp.TryGetProperty("Password", out var password))
            {
                var value = password.ValueKind == JsonValueKind.String ? password.GetString() : null;
                Assert.True(string.IsNullOrEmpty(value), file);
            }

            if (document.RootElement.TryGetProperty("Auth", out var auth)
                && auth.TryGetProperty("Supabase", out var supabase)
                && supabase.TryGetProperty("ServiceRoleKey", out var serviceRole))
            {
                var value = serviceRole.ValueKind == JsonValueKind.String ? serviceRole.GetString() : null;
                Assert.True(string.IsNullOrEmpty(value), file);
            }
        }

        var workflow = File.ReadAllText(Path.Combine(root, ".github", "workflows", "deploy-aca.yml"));
        Assert.Contains("secrets.SMTP_PASSWORD", workflow, StringComparison.Ordinal);
        Assert.Contains("secrets.SUPABASE_SERVICE_ROLE_KEY", workflow, StringComparison.Ordinal);
        Assert.Contains("Smtp__Password=secretref:smtp-password", workflow, StringComparison.Ordinal);
        Assert.Contains("Auth__Supabase__ServiceRoleKey=secretref:supabase-service-role", workflow, StringComparison.Ordinal);
        Assert.Contains("refs/heads/main", workflow, StringComparison.Ordinal);
        Assert.DoesNotContain("pull_request:", workflow, StringComparison.Ordinal);
        var assignments = workflow
            .Replace("Smtp__Password=secretref:smtp-password", "", StringComparison.Ordinal)
            .Replace("Auth__Supabase__ServiceRoleKey=secretref:supabase-service-role", "", StringComparison.Ordinal);
        Assert.DoesNotContain("Smtp__Password=", assignments, StringComparison.Ordinal);
        Assert.DoesNotContain("ServiceRoleKey=", assignments, StringComparison.Ordinal);
    }

    private static string FindRepo()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "backend", "Hms.slnx")))
            {
                return dir.FullName;
            }
        }

        throw new InvalidOperationException("repository root not found above the test output directory.");
    }
}

public sealed class PasswordlessSessionIssuerTests
{
    [Fact]
    public async Task An_empty_service_role_key_does_not_call_GoTrue()
    {
        var handler = new RecordingHandler();
        var issuer = Issuer(handler, serviceRoleKey: "");
        Assert.False(issuer.IsConfigured);
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => issuer.CreateAsync("person@synthetic.example", CancellationToken.None));
        Assert.Equal(GoTruePasswordlessSessionIssuer.NotConfiguredMessage, error.Message);
        Assert.Empty(handler.Requests);
        Assert.DoesNotContain("person@", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_new_user_and_an_existing_user_both_return_the_token_hash()
    {
        var handler = new RecordingHandler(
            new HttpResponseMessage(HttpStatusCode.UnprocessableEntity),
            JsonResponse("""{"hashed_token":"hash-from-root","verification_type":"magiclink","email_otp":"999999"}"""));
        var issuer = Issuer(handler, "test-service-role-key");
        var proof = await issuer.CreateAsync("person@synthetic.example", CancellationToken.None);
        Assert.Equal("hash-from-root", proof.TokenHash);
        Assert.Equal("magiclink", proof.VerificationType);
        Assert.Equal(2, handler.Requests.Count);
        Assert.Equal("Bearer test-service-role-key", handler.Requests[0].Headers.Authorization?.ToString());
        Assert.DoesNotContain("999999", proof.TokenHash, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_nested_hashed_token_is_accepted()
    {
        var handler = new RecordingHandler(
            new HttpResponseMessage(HttpStatusCode.OK),
            JsonResponse("""{"properties":{"hashed_token":"hash-nested"}}"""));
        var proof = await Issuer(handler, "test-service-role-key").CreateAsync("person@synthetic.example", CancellationToken.None);
        Assert.Equal("hash-nested", proof.TokenHash);
    }

    private static GoTruePasswordlessSessionIssuer Issuer(RecordingHandler handler, string serviceRoleKey) =>
        new(new HttpClient(handler), Options.Create(new SupabaseAuthOptions
        {
            ProjectUrl = "https://auth.example.test",
            ServiceRoleKey = serviceRoleKey,
        }));

    private static HttpResponseMessage JsonResponse(string json) =>
        new(HttpStatusCode.OK) { Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json") };

    private sealed class RecordingHandler(params HttpResponseMessage[] responses) : HttpMessageHandler
    {
        public List<HttpRequestMessage> Requests { get; } = [];

        private int _index;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(request);
            var response = responses.Length == 0
                ? new HttpResponseMessage(HttpStatusCode.InternalServerError)
                : responses[Math.Min(_index, responses.Length - 1)];
            _index++;
            return Task.FromResult(response);
        }
    }
}
