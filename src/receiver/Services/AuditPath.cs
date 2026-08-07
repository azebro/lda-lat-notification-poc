using System.Globalization;
using DeltaNotificationReceiver.Models;

namespace DeltaNotificationReceiver.Services;

public static class AuditPath
{
    public static string For(DeltaChangeEnvelope envelope)
    {
        var commitDate = envelope.CommitTimestamp.UtcDateTime.ToString("yyyy/MM/dd", CultureInfo.InvariantCulture);
        return $"events/{envelope.Catalog}/{envelope.Schema}/{envelope.Table}/{commitDate}/{envelope.EventId}.json";
    }
}