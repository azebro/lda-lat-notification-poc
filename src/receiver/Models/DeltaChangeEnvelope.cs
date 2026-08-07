using System.Text.Json.Serialization;

namespace DeltaNotificationReceiver.Models;

public sealed record DeltaChangeEnvelope
{
    [JsonPropertyName("event_id")]
    public required string EventId { get; init; }

    [JsonPropertyName("source")]
    public required string Source { get; init; }

    [JsonPropertyName("catalog")]
    public required string Catalog { get; init; }

    [JsonPropertyName("schema")]
    public required string Schema { get; init; }

    [JsonPropertyName("table")]
    public required string Table { get; init; }

    [JsonPropertyName("primary_key")]
    public required string PrimaryKey { get; init; }

    [JsonPropertyName("change_type")]
    public required string ChangeType { get; init; }

    [JsonPropertyName("commit_version")]
    public required long CommitVersion { get; init; }

    [JsonPropertyName("commit_timestamp")]
    public required DateTimeOffset CommitTimestamp { get; init; }

    [JsonPropertyName("payload")]
    public required VehicleSignalPayload Payload { get; init; }
}

public sealed record VehicleSignalPayload
{
    [JsonPropertyName("signal_id")]
    public required string SignalId { get; init; }

    [JsonPropertyName("vehicle_id")]
    public required string VehicleId { get; init; }

    [JsonPropertyName("signal_type")]
    public required string SignalType { get; init; }

    [JsonPropertyName("signal_value")]
    public required double SignalValue { get; init; }

    [JsonPropertyName("event_timestamp")]
    public required DateTimeOffset EventTimestamp { get; init; }

    [JsonPropertyName("updated_at")]
    public required DateTimeOffset UpdatedAt { get; init; }
}