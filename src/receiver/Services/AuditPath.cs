using DeltaNotificationReceiver.Models;

namespace DeltaNotificationReceiver.Services;

public static class AuditPath
{
    public static string For(DeltaChangeEnvelope envelope)
    {
        var commitDate = envelope.CommitTimestamp.UtcDateTime;
        return $"events/{envelope.Catalog}/{envelope.Schema}/{envelope.Table}/{commitDate:yyyy/MM/dd}/{envelope.EventId}.json";
    }
}