using System.Text.Json;
using Azure.Messaging.EventHubs;

namespace DeltaNotificationReceiver.Services;

public sealed record EventMetadata(
    string PartitionId,
    string Offset,
    long SequenceNumber,
    DateTimeOffset EnqueuedTime,
    string? PartitionKey);

public static class EventMetadataExtractor
{
    public static EventMetadata Extract(
        EventData eventData,
        IReadOnlyDictionary<string, object?> bindingData)
    {
        var partitionId = ReadPartitionId(bindingData)
            ?? throw new InvalidOperationException("Event Hubs partition metadata is required.");

        return new EventMetadata(
            partitionId,
            eventData.Offset.ToString(),
            eventData.SequenceNumber,
            eventData.EnqueuedTime,
            eventData.PartitionKey);
    }

    private static string? ReadPartitionId(IReadOnlyDictionary<string, object?> bindingData)
    {
        if (TryReadString(bindingData, "PartitionId", out var partitionId))
        {
            return partitionId;
        }

        if (!bindingData.TryGetValue("PartitionContext", out var context) || context is null)
        {
            return null;
        }

        if (context is JsonElement { ValueKind: JsonValueKind.Object } element
            && TryReadString(element, "PartitionId", out partitionId))
        {
            return partitionId;
        }

        if (context is IReadOnlyDictionary<string, object?> readOnlyContext
            && TryReadString(readOnlyContext, "PartitionId", out partitionId))
        {
            return partitionId;
        }

        if (context is IDictionary<string, object> dictionaryContext
            && dictionaryContext.TryGetValue("PartitionId", out var value))
        {
            return Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
        }

        return null;
    }

    private static bool TryReadString(
        IReadOnlyDictionary<string, object?> values,
        string key,
        out string? result)
    {
        if (values.TryGetValue(key, out var value))
        {
            result = Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
            return !string.IsNullOrWhiteSpace(result);
        }

        result = null;
        return false;
    }

    private static bool TryReadString(JsonElement element, string name, out string? result)
    {
        foreach (var property in element.EnumerateObject())
        {
            if (!property.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            result = property.Value.ValueKind == JsonValueKind.String
                ? property.Value.GetString()
                : property.Value.GetRawText();
            return !string.IsNullOrWhiteSpace(result);
        }

        result = null;
        return false;
    }
}