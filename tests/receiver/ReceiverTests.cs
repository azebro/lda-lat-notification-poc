using System.Globalization;
using Azure;
using Azure.Messaging.EventHubs;
using Azure.Storage.Blobs.Models;
using DeltaNotificationReceiver.Models;
using DeltaNotificationReceiver.Services;
using Microsoft.Extensions.Logging;

namespace DeltaNotificationReceiver.Tests;

[TestClass]
public sealed class ReceiverTests
{
    [TestMethod]
    public void Parse_ValidEnvelope_ReturnsContractValues()
    {
        var envelope = new DeltaChangeEnvelopeParser().Parse(ValidBody());

        Assert.AreEqual("vehicle_signals-signal-001-v42-insert", envelope.EventId);
        Assert.AreEqual("signal-001", envelope.PrimaryKey);
        Assert.AreEqual(42, envelope.CommitVersion);
        Assert.AreEqual(12.5, envelope.Payload.SignalValue);
    }

    [TestMethod]
    [DataRow("\"commit_version\":42,", "")]
    [DataRow("\"change_type\":\"insert\"", "\"change_type\":\"delete\"")]
    [DataRow("\"primary_key\":\"signal-001\"", "\"primary_key\":\"other\"")]
    [DataRow("\"payload\":{", "\"unexpected\":true,\"payload\":{")]
    [DataRow("\"vehicle_id\":\"vehicle-001\"", "\"vehicle_id\":null")]
    [DataRow("\"signal_value\":12.5", "\"unexpected\":true,\"signal_value\":12.5")]
    [DataRow("\"source\":\"azure-databricks\"", "\"source\":\"other\"")]
    public void Parse_InvalidEnvelope_Throws(string oldValue, string newValue)
    {
        var body = BinaryData.FromString(ValidBody().ToString().Replace(oldValue, newValue, StringComparison.Ordinal));

        Assert.Throws<EnvelopeValidationException>(() => new DeltaChangeEnvelopeParser().Parse(body));
    }

    [TestMethod]
    public void Parse_MalformedJson_ThrowsValidationException()
    {
        Assert.Throws<EnvelopeValidationException>(() =>
            new DeltaChangeEnvelopeParser().Parse(BinaryData.FromString("{\"event_id\":")));
    }

    [TestMethod]
    public void AuditPath_UsesCommitTimestampInUtc()
    {
        var envelope = ValidEnvelope() with
        {
            CommitTimestamp = DateTimeOffset.Parse("2026-08-05T00:30:00+02:00")
        };

        var path = AuditPath.For(envelope);

        Assert.AreEqual(
            "events/poc_notifications/main/vehicle_signals/2026/08/04/vehicle_signals-signal-001-v42-insert.json",
            path);
    }

    [TestMethod]
    public void AuditPath_IsCultureInvariant()
    {
        var original = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = new CultureInfo("de-DE");

        try
        {
            Assert.AreEqual(
                "events/poc_notifications/main/vehicle_signals/2026/08/05/vehicle_signals-signal-001-v42-insert.json",
                AuditPath.For(ValidEnvelope()));
        }
        finally
        {
            CultureInfo.CurrentCulture = original;
        }
    }

    [TestMethod]
    public async Task BlobAuditWriter_NewBlob_ReturnsCreatedAndPreservesBody()
    {
        var store = new RecordingBlobStore();
        var writer = new BlobAuditWriter(store);
        using var cancellation = new CancellationTokenSource();
        var body = ValidBody();

        var result = await writer.WriteAsync(ValidEnvelope(), body, cancellation.Token);

        Assert.AreEqual(AuditWriteResult.Created, result);
        Assert.AreEqual(AuditPath.For(ValidEnvelope()), store.Path);
        Assert.AreEqual(body.ToString(), store.Content?.ToString());
        Assert.AreEqual(cancellation.Token, store.CancellationToken);
    }

    [TestMethod]
    public async Task BlobAuditWriter_BlobAlreadyExists_ReturnsDuplicate()
    {
        var store = new ThrowingBlobStore(
            new RequestFailedException(409, "duplicate", BlobErrorCode.BlobAlreadyExists.ToString(), null));
        var writer = new BlobAuditWriter(store);

        var result = await writer.WriteAsync(ValidEnvelope(), ValidBody(), CancellationToken.None);

        Assert.AreEqual(AuditWriteResult.Duplicate, result);
    }

    [TestMethod]
    public async Task BlobAuditWriter_IfNoneMatchConditionNotMet_ReturnsDuplicate()
    {
        var store = new ThrowingBlobStore(
            new RequestFailedException(412, "condition failed", BlobErrorCode.ConditionNotMet.ToString(), null));
        var writer = new BlobAuditWriter(store);

        var result = await writer.WriteAsync(ValidEnvelope(), ValidBody(), CancellationToken.None);

        Assert.AreEqual(AuditWriteResult.Duplicate, result);
    }

    [TestMethod]
    public async Task BlobAuditWriter_OtherConflict_Propagates()
    {
        var failure = new RequestFailedException(409, "lease conflict", "LeaseIdMissing", null);
        var writer = new BlobAuditWriter(new ThrowingBlobStore(failure));

        var actual = await Assert.ThrowsExactlyAsync<RequestFailedException>(
            () => writer.WriteAsync(ValidEnvelope(), ValidBody(), CancellationToken.None));

        Assert.AreSame(failure, actual);
    }

    [TestMethod]
    public async Task Processor_Duplicate_EmitsStructuredEventMetadata()
    {
        var auditWriter = new StubAuditWriter(AuditWriteResult.Duplicate);
        var logger = new RecordingLogger<DeltaChangeProcessor>();
        var processor = new DeltaChangeProcessor(auditWriter, logger);
        var enqueuedTime = DateTimeOffset.UtcNow.AddSeconds(-1);
        var metadata = new EventMetadata("1", "9001", 42, enqueuedTime, "signal-001");

        var processed = await processor.ProcessAsync(ValidBody(), metadata, CancellationToken.None);

        Assert.IsTrue(processed.Duplicate);
        Assert.AreEqual("DeltaChangeProcessed", logger.Properties["microsoft.custom_event.name"]);
        Assert.AreEqual("vehicle_signals-signal-001-v42-insert", logger.Properties["event_id"]);
        Assert.AreEqual("1", logger.Properties["partition"]);
        Assert.AreEqual("9001", logger.Properties["offset"]);
        Assert.AreEqual(42L, logger.Properties["sequence_number"]);
        Assert.AreEqual(DateTimeOffset.Parse("2026-08-05T12:34:56Z"), logger.Properties["commit_timestamp"]);
        Assert.AreEqual(enqueuedTime, logger.Properties["event_hubs_enqueued_time"]);
        Assert.IsTrue((double)logger.Properties["receiver_latency_ms"]! >= 0);
        Assert.AreEqual(true, logger.Properties["duplicate"]);
    }

    [TestMethod]
    public async Task Processor_Created_EmitsNonDuplicateEvent()
    {
        var logger = new RecordingLogger<DeltaChangeProcessor>();
        var processor = new DeltaChangeProcessor(new StubAuditWriter(AuditWriteResult.Created), logger);

        var processed = await processor.ProcessAsync(
            ValidBody(),
            new EventMetadata("0", "1", 1, DateTimeOffset.UtcNow, "signal-001"),
            CancellationToken.None);

        Assert.IsFalse(processed.Duplicate);
        Assert.AreEqual(false, logger.Properties["duplicate"]);
        Assert.AreEqual("poc_notifications", logger.Properties["catalog"]);
        Assert.AreEqual("main", logger.Properties["schema"]);
        Assert.AreEqual("vehicle_signals", logger.Properties["table"]);
        Assert.AreEqual("signal-001", logger.Properties["primary_key"]);
        Assert.AreEqual("insert", logger.Properties["change_type"]);
        Assert.AreEqual(42L, logger.Properties["commit_version"]);
    }

    [TestMethod]
    public async Task Processor_InvalidEnvelope_EmitsFailureEventAndPropagates()
    {
        var logger = new RecordingLogger<DeltaChangeProcessor>();
        var processor = new DeltaChangeProcessor(new StubAuditWriter(AuditWriteResult.Created), logger);
        var metadata = new EventMetadata("1", "9001", 42, DateTimeOffset.UtcNow, null);

        await Assert.ThrowsAsync<EnvelopeValidationException>(() => processor.ProcessAsync(
            BinaryData.FromString("{}"),
            metadata,
            CancellationToken.None));

        Assert.AreEqual("DeltaChangeValidationFailed", logger.Properties["microsoft.custom_event.name"]);
        Assert.AreEqual("1", logger.Properties["partition"]);
        Assert.AreEqual("9001", logger.Properties["offset"]);
        Assert.AreEqual(42L, logger.Properties["sequence_number"]);
    }

    [TestMethod]
    public async Task Processor_StorageFailure_EmitsFailureEventAndPropagates()
    {
        var failure = new RequestFailedException(503, "busy", BlobErrorCode.ServerBusy.ToString(), null);
        var logger = new RecordingLogger<DeltaChangeProcessor>();
        var processor = new DeltaChangeProcessor(new ThrowingAuditWriter(failure), logger);

        var actual = await Assert.ThrowsExactlyAsync<RequestFailedException>(() => processor.ProcessAsync(
            ValidBody(),
            new EventMetadata("0", "1", 1, DateTimeOffset.UtcNow, "signal-001"),
            CancellationToken.None));

        Assert.AreSame(failure, actual);
        Assert.AreEqual("DeltaChangePersistenceFailed", logger.Properties["microsoft.custom_event.name"]);
        Assert.AreEqual("vehicle_signals-signal-001-v42-insert", logger.Properties["event_id"]);
    }

    [TestMethod]
    public async Task Processor_Cancellation_PropagatesOriginalToken()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var processor = new DeltaChangeProcessor(
            new CancellingAuditWriter(),
            new RecordingLogger<DeltaChangeProcessor>());

        var exception = await Assert.ThrowsAsync<OperationCanceledException>(
            () => processor.ProcessAsync(
                ValidBody(),
                new EventMetadata("0", "1", 1, DateTimeOffset.UtcNow, "signal-001"),
                cancellation.Token));

        Assert.AreEqual(cancellation.Token, exception.CancellationToken);
    }

    [TestMethod]
    public void EventMetadataExtractor_ReadsSdkAndBindingMetadata()
    {
        var enqueuedTime = DateTimeOffset.Parse("2026-08-05T12:34:56Z");
        var eventData = EventHubsModelFactory.EventData(
            ValidBody(),
            new Dictionary<string, object>(),
            new Dictionary<string, object>(),
            "signal-001",
            73,
            9001L,
            enqueuedTime);

        var metadata = EventMetadataExtractor.Extract(
            eventData,
            new Dictionary<string, object?> { ["PartitionId"] = "1" });

        Assert.AreEqual("1", metadata.PartitionId);
        Assert.AreEqual("9001", metadata.Offset);
        Assert.AreEqual(73, metadata.SequenceNumber);
        Assert.AreEqual(enqueuedTime, metadata.EnqueuedTime);
        Assert.AreEqual("signal-001", metadata.PartitionKey);
    }

    [TestMethod]
    public void EventMetadataExtractor_MissingPartition_Throws()
    {
        Assert.Throws<InvalidOperationException>(() => EventMetadataExtractor.Extract(
            new EventData(ValidBody()),
            new Dictionary<string, object?>()));
    }

    [TestMethod]
    public void EventMetadataExtractor_ReadsCamelCasePartitionContext()
    {
        using var contextDocument = System.Text.Json.JsonDocument.Parse("{\"partitionId\":\"1\"}");

        var metadata = EventMetadataExtractor.Extract(
            new EventData(ValidBody()),
            new Dictionary<string, object?>
            {
                ["PartitionContext"] = contextDocument.RootElement.Clone()
            });

        Assert.AreEqual("1", metadata.PartitionId);
    }

    private static BinaryData ValidBody() => BinaryData.FromString(
        """
        {
          "event_id":"vehicle_signals-signal-001-v42-insert",
          "source":"azure-databricks",
          "catalog":"poc_notifications",
          "schema":"main",
          "table":"vehicle_signals",
          "primary_key":"signal-001",
          "change_type":"insert",
          "commit_version":42,
          "commit_timestamp":"2026-08-05T12:34:56Z",
          "payload":{
            "signal_id":"signal-001",
            "vehicle_id":"vehicle-001",
            "signal_type":"temperature",
            "signal_value":12.5,
            "event_timestamp":"2026-08-05T12:30:00Z",
            "updated_at":"2026-08-05T12:34:55Z"
          }
        }
        """);

    private static DeltaChangeEnvelope ValidEnvelope() =>
        new DeltaChangeEnvelopeParser().Parse(ValidBody());

    private sealed class RecordingBlobStore : IAuditBlobStore
    {
        public string? Path { get; private set; }

        public BinaryData? Content { get; private set; }

        public CancellationToken CancellationToken { get; private set; }

        public Task UploadIfAbsentAsync(
            string blobPath,
            BinaryData content,
            CancellationToken cancellationToken)
        {
            Path = blobPath;
            Content = content;
            CancellationToken = cancellationToken;
            return Task.CompletedTask;
        }
    }

    private sealed class ThrowingBlobStore(Exception exception) : IAuditBlobStore
    {
        public Task UploadIfAbsentAsync(
            string blobPath,
            BinaryData content,
            CancellationToken cancellationToken) => Task.FromException(exception);
    }

    private sealed class StubAuditWriter(AuditWriteResult result) : IAuditWriter
    {
        public Task<AuditWriteResult> WriteAsync(
            DeltaChangeEnvelope envelope,
            BinaryData canonicalJson,
            CancellationToken cancellationToken) => Task.FromResult(result);
    }

    private sealed class CancellingAuditWriter : IAuditWriter
    {
        public Task<AuditWriteResult> WriteAsync(
            DeltaChangeEnvelope envelope,
            BinaryData canonicalJson,
            CancellationToken cancellationToken) => Task.FromCanceled<AuditWriteResult>(cancellationToken);
    }

    private sealed class ThrowingAuditWriter(Exception exception) : IAuditWriter
    {
        public Task<AuditWriteResult> WriteAsync(
            DeltaChangeEnvelope envelope,
            BinaryData canonicalJson,
            CancellationToken cancellationToken) => Task.FromException<AuditWriteResult>(exception);
    }

    private sealed class RecordingLogger<T> : ILogger<T>
    {
        public Dictionary<string, object?> Properties { get; } = [];

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            if (state is not IEnumerable<KeyValuePair<string, object?>> values)
            {
                return;
            }

            foreach (var pair in values.Where(pair => pair.Key != "{OriginalFormat}"))
            {
                Properties[pair.Key] = pair.Value;
            }
        }
    }
}