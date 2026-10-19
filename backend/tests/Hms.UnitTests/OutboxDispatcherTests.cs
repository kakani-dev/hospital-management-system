using Hms.Platform.Messaging;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Hms.UnitTests;

public sealed class OutboxDispatcherTests
{
    private sealed class FakeStore : IOutboxStore
    {
        public Queue<IReadOnlyList<OutboxMessage>> Batches { get; } = new();

        public List<long> Completed { get; } = [];

        public List<(long Id, string Error, TimeSpan RetryIn)> Failed { get; } = [];

        public Task<IReadOnlyList<OutboxMessage>> ClaimAsync(string workerId, int batchSize, TimeSpan lease, CancellationToken ct) =>
            Task.FromResult(Batches.Count > 0 ? Batches.Dequeue() : (IReadOnlyList<OutboxMessage>)[]);

        public Task CompleteAsync(long id, string workerId, CancellationToken ct)
        {
            Completed.Add(id);
            return Task.CompletedTask;
        }

        public Task FailAsync(long id, string workerId, string errorMessage, TimeSpan retryIn, CancellationToken ct)
        {
            Failed.Add((id, errorMessage, retryIn));
            return Task.CompletedTask;
        }
    }

    private sealed class FakePublisher(Func<OutboxMessage, bool> fails) : IOutboxPublisher
    {
        public List<Guid> Published { get; } = [];

        public Task PublishAsync(OutboxMessage message, CancellationToken ct)
        {
            if (fails(message))
            {
                throw new InvalidOperationException("broker down");
            }

            Published.Add(message.EventId);
            return Task.CompletedTask;
        }
    }

    private static OutboxMessage Message(long id, Guid eventId, int attempts = 1) =>
        new(id, eventId, Guid.NewGuid(), "appointment", Guid.NewGuid(), "appointment.booked", "{}", DateTimeOffset.UnixEpoch, attempts);

    private static OutboxDispatcher Dispatcher(FakeStore store, FakePublisher publisher) =>
        new(store, publisher, Options.Create(new OutboxOptions { RetryBaseSeconds = 10 }), TimeProvider.System, NullLogger<OutboxDispatcher>.Instance);

    [Fact]
    public async Task Publishes_then_completes_and_dedupes_on_event_id()
    {
        var store = new FakeStore();
        var publisher = new FakePublisher(_ => false);
        var dispatcher = Dispatcher(store, publisher);
        var eventId = Guid.NewGuid();
        store.Batches.Enqueue([Message(1, eventId), Message(2, Guid.NewGuid())]);
        store.Batches.Enqueue([Message(1, eventId, attempts: 2)]); // lost ack -> re-claimed

        Assert.Equal(2, await dispatcher.RunOnceAsync(CancellationToken.None));
        Assert.Equal(1, await dispatcher.RunOnceAsync(CancellationToken.None));
        Assert.Equal(0, await dispatcher.RunOnceAsync(CancellationToken.None));

        Assert.Equal(2, publisher.Published.Count);           // event_id published once
        Assert.Equal([1L, 2L, 1L], store.Completed);           // but acknowledged again
        Assert.Empty(store.Failed);
    }

    [Fact]
    public async Task A_failing_message_is_failed_with_exponential_backoff_and_does_not_stop_the_batch()
    {
        var store = new FakeStore();
        var poison = Guid.NewGuid();
        var publisher = new FakePublisher(m => m.EventId == poison);
        var dispatcher = Dispatcher(store, publisher);
        store.Batches.Enqueue([Message(1, poison, attempts: 3), Message(2, Guid.NewGuid())]);

        await dispatcher.RunOnceAsync(CancellationToken.None);

        var failed = Assert.Single(store.Failed);
        Assert.Equal(1, failed.Id);
        Assert.Equal(TimeSpan.FromSeconds(40), failed.RetryIn); // 10s * 2^(3-1)
        Assert.Contains("broker down", failed.Error, StringComparison.Ordinal);
        Assert.Equal([2L], store.Completed);
    }

    [Theory]
    [InlineData(1, 30, 30)]
    [InlineData(2, 30, 60)]
    [InlineData(4, 30, 240)]
    [InlineData(50, 30, 3600)]
    [InlineData(0, 0, 1)]
    public async Task Retry_delay_doubles_and_is_capped(int attempts, int baseSeconds, int expectedSeconds)
    {
        var store = new FakeStore();
        var poison = Guid.NewGuid();
        store.Batches.Enqueue([Message(1, poison, attempts)]);
        var dispatcher = new OutboxDispatcher(store, new FakePublisher(_ => true),
            Options.Create(new OutboxOptions { RetryBaseSeconds = baseSeconds }), TimeProvider.System, NullLogger<OutboxDispatcher>.Instance);

        await dispatcher.RunOnceAsync(CancellationToken.None);

        Assert.Equal(TimeSpan.FromSeconds(expectedSeconds), Assert.Single(store.Failed).RetryIn);
    }
}
