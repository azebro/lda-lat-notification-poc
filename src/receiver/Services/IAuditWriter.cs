using DeltaNotificationReceiver.Models;

namespace DeltaNotificationReceiver.Services;

public interface IAuditWriter
{
    Task<AuditWriteResult> WriteAsync(
        DeltaChangeEnvelope envelope,
        BinaryData canonicalJson,
        CancellationToken cancellationToken);
}

public enum AuditWriteResult
{
    Created,
    Duplicate
}