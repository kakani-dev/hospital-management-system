using Hms.Platform.Persistence;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hms.Modules.Identity.Email;

public static class EmailDeliverySetup
{
    /// <summary>
    /// Registers the Gmail sender and the identity email worker. Call this from the identity
    /// service only. The legacy host must not (B1: it cannot assume <c>hms_mailer</c>, and its
    /// outbox dispatcher stays off). The worker no-ops until <c>Email:Dispatcher:Enabled</c> is true.
    /// </summary>
    public static IServiceCollection AddIdentityEmailDelivery(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddHmsDatabase(configuration);
        services.Configure<SmtpOptions>(configuration.GetSection(SmtpOptions.Section));
        services.Configure<EmailDeliveryOptions>(configuration.GetSection(EmailDeliveryOptions.Section));
        services.TryAddSingleton(TimeProvider.System);
        services.AddSingleton<IEmailSender, SmtpEmailSender>();
        services.AddSingleton<IEmailOutbox, PostgresEmailOutbox>();
        services.AddHostedService<EmailOutboxDispatcher>();
        return services;
    }
}
