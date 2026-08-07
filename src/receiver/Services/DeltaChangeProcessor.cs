using DeltaNotificationReceiver.Models;
using Microsoft.Extensions.Logging;

namespace DeltaNotificationReceiver.Services;

public sealed class DeltaChangeProcessor(
    IAuditWriter auditWriter,
    ILogger<DeltaChangeProcessor> logger)
{
    private readonly DeltaChangeEnvelopeParser _parser = new();

    public async Task<ProcessedDeltaChange> ProcessAsync(
        BinaryData body,
        EventMetadata metadata,
        CancellationToken cancellationToken)
    {
        DeltaChangeEnvelope envelope;

        try
        {
            envelope = _parser.Parse(body);
        }
        catch (EnvelopeValidationException exception)
        {
            logger.LogWarning(
                exception,
                "{microsoft.custom_event.name} Rejected Delta change from Event Hubs partition {partition}, " +
                "offset {offset}, sequence {sequence_number}; failure_type={failure_type}",
                "DeltaChangeValidationFailed",
                metadata.PartitionId,
                metadata.Offset,
                metadata.SequenceNumber,
                exception.GetType().Name);
            throw;
        }

        AuditWriteResult writeResult;

        try
        {
            writeResult = await auditWriter.WriteAsync(envelope, body, cancellationToken);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            logger.LogError(
                exception,
                "{microsoft.custom_event.name} Failed to persist Delta change {event_id} from " +
                "{catalog}.{schema}.{table}; Event Hubs partition {partition}, offset {offset}, " +
                "sequence {sequence_number}; failure_type={failure_type}",
                "DeltaChangePersistenceFailed",
                envelope.EventId,
                envelope.Catalog,
                envelope.Schema,
                envelope.Table,
                metadata.PartitionId,
                metadata.Offset,
                metadata.SequenceNumber,
                exception.GetType().Name);
            throw;
        }

        var duplicate = writeResult == AuditWriteResult.Duplicate;
        var receiverLatencyMs = Math.Max(
            0,
            (DateTimeOffset.UtcNow - metadata.EnqueuedTime).TotalMilliseconds);

        logger.LogInformation(
            "{microsoft.custom_event.name} Processed Delta change {event_id} from {catalog}.{schema}.{table} " +
            "for {primary_key} as {change_type} at commit {commit_version} ({commit_timestamp}); " +
            "Event Hubs partition {partition}, offset {offset}, sequence {sequence_number}, enqueued " +
            "{event_hubs_enqueued_time}; receiver_latency_ms={receiver_latency_ms}; duplicate={duplicate}",
            "DeltaChangeProcessed",
            envelope.EventId,
            envelope.Catalog,
            envelope.Schema,
            envelope.Table,
            envelope.PrimaryKey,
            envelope.ChangeType,
            envelope.CommitVersion,
            envelope.CommitTimestamp,
            metadata.PartitionId,
            metadata.Offset,
            metadata.SequenceNumber,
            metadata.EnqueuedTime,
            receiverLatencyMs,
            duplicate);

        return new ProcessedDeltaChange(envelope, metadata, duplicate);
    }
}

public sealed record ProcessedDeltaChange(
    DeltaChangeEnvelope Envelope,
    EventMetadata Metadata,
    bool Duplicate);