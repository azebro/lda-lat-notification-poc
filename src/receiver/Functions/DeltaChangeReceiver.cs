using Azure.Messaging.EventHubs;
using DeltaNotificationReceiver.Services;
using Microsoft.Azure.Functions.Worker;

namespace DeltaNotificationReceiver.Functions;

public sealed class DeltaChangeReceiver(DeltaChangeProcessor processor)
{
    [Function(nameof(DeltaChangeReceiver))]
    [FixedDelayRetry(5, "00:00:10")]
    public async Task RunAsync(
        [EventHubTrigger(
            "%EVENT_HUB_NAME%",
            ConsumerGroup = "%EVENT_HUB_CONSUMER_GROUP%",
            Connection = "EventHubConnection",
            IsBatched = false)]
        EventData eventData,
        FunctionContext context,
        CancellationToken cancellationToken)
    {
        var metadata = EventMetadataExtractor.Extract(eventData, context.BindingContext.BindingData);
        await processor.ProcessAsync(eventData.EventBody, metadata, cancellationToken);
    }
}