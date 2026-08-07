using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using DeltaNotificationReceiver.Models;

namespace DeltaNotificationReceiver.Services;

public sealed partial class DeltaChangeEnvelopeParser
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public DeltaChangeEnvelope Parse(BinaryData body)
    {
        DeltaChangeEnvelope envelope;

        try
        {
            envelope = JsonSerializer.Deserialize<DeltaChangeEnvelope>(body, SerializerOptions)
                ?? throw new EnvelopeValidationException("The event body must contain a JSON object.");
        }
        catch (JsonException exception)
        {
            throw new EnvelopeValidationException("The event body does not match the v1 envelope contract.", exception);
        }

        Validate(envelope);
        return envelope;
    }

    private static void Validate(DeltaChangeEnvelope envelope)
    {
        Require(!string.IsNullOrWhiteSpace(envelope.EventId), "event_id is required.");
        Require(envelope.Source == "azure-databricks", "source must be azure-databricks.");
        Require(envelope.Catalog == "poc_notifications", "catalog must be poc_notifications.");
        Require(envelope.Schema == "main", "schema must be main.");
        Require(envelope.Table == "vehicle_signals", "table must be vehicle_signals.");
        Require(!string.IsNullOrWhiteSpace(envelope.PrimaryKey)
            && KeyPattern().IsMatch(envelope.PrimaryKey), "primary_key is invalid.");
        Require(envelope.ChangeType is "insert" or "update_postimage", "change_type is invalid.");
        Require(envelope.CommitVersion >= 0, "commit_version must be non-negative.");

        var payload = envelope.Payload
            ?? throw new EnvelopeValidationException("payload is required.");
        Require(!string.IsNullOrWhiteSpace(payload.SignalId)
            && KeyPattern().IsMatch(payload.SignalId), "payload.signal_id is invalid.");
        Require(!string.IsNullOrWhiteSpace(payload.VehicleId), "payload.vehicle_id is required.");
        Require(!string.IsNullOrWhiteSpace(payload.SignalType), "payload.signal_type is required.");
        Require(double.IsFinite(payload.SignalValue), "payload.signal_value must be finite.");
        Require(envelope.PrimaryKey == payload.SignalId, "primary_key must equal payload.signal_id.");

        var expectedEventId = $"vehicle_signals-{payload.SignalId}-v{envelope.CommitVersion}-{envelope.ChangeType}";
        Require(envelope.EventId == expectedEventId, "event_id does not match the deterministic identity.");
        Require(EventIdPattern().IsMatch(envelope.EventId), "event_id is invalid.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new EnvelopeValidationException(message);
        }
    }

    [GeneratedRegex("^[A-Za-z0-9._-]+$", RegexOptions.CultureInvariant)]
    private static partial Regex KeyPattern();

    [GeneratedRegex("^vehicle_signals-[A-Za-z0-9._-]+-v[0-9]+-(insert|update_postimage)$", RegexOptions.CultureInvariant)]
    private static partial Regex EventIdPattern();
}

public sealed class EnvelopeValidationException : Exception
{
    public EnvelopeValidationException(string message)
        : base(message)
    {
    }

    public EnvelopeValidationException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}