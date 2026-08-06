# Publish/Subscribe Patterns for Delta Change Data Feed (CDF) Notifications on Azure Databricks

## Executive Summary

For enterprise-grade Delta table change notification, the recommended architecture is:

```text
Delta Table
     │
     ▼
Change Data Feed (CDF)
     │
     ▼
Structured Streaming Publisher
     │
     ├────────► Event Hubs (Streaming Consumers)
     │
     ├────────► Service Bus Topics (Business Applications)
     │
     └────────► Event Grid (Lightweight Notifications)
```

**Key Recommendation**

- Use **Delta Change Data Feed (CDF)** as the authoritative source of table changes.
- Use **Azure Event Hubs** for high-volume streaming and analytics consumers.
- Use **Azure Service Bus Topics** for enterprise application integration.
- Use **Azure Event Grid** only when subscribers need notification that something changed, not the actual changed data.
- Keep Databricks responsible for publishing CDF events once and allow downstream systems to subscribe independently.

---

# Pattern 1: Delta CDF → Azure Event Hubs

## Architecture

```text
Delta Table
      │
      ▼
Change Data Feed
      │
      ▼
Databricks Structured Streaming
      │
      ▼
Azure Event Hubs
      │
 ┌────┼─────────────┬──────────┐
 ▼    ▼             ▼          ▼
App1 App2      Fabric      Search Index
```

## When to Use

Recommended when:

- Multiple consumers require the same changes
- Replay capability is required
- High throughput is needed
- Near real-time processing is required
- Streaming analytics are involved

Typical use cases:

- Microsoft Fabric
- Real-time dashboards
- Search indexing
- AI applications
- Event-driven architectures

---

## Reading Delta Change Data Feed

```python
cdf = (
    spark.readStream
         .option("readChangeFeed","true")
         .table("lda.vehicle_signals")
)
```

Returned schema includes:

| Column | Description |
|----------|-------------|
| _change_type | insert/update/delete |
| _commit_version | Delta transaction version |
| _commit_timestamp | Commit timestamp |
| business columns | Actual changed data |

Example:

```text
signal_id vehicle_id value _change_type _commit_version
123       VOLVO001   50    insert       1001
123       VOLVO001   60    update       1002
```

---

## Building a Standard Event Envelope

Avoid publishing raw table rows.

Instead create a consistent event contract.

```python
from pyspark.sql.functions import struct,to_json

events = (
    cdf.select(
        col("vehicle_id").alias("key"),
        to_json(
            struct(
                "_change_type",
                "_commit_version",
                "_commit_timestamp",
                "vehicle_id",
                "signal_id",
                "value"
            )
        ).alias("value")
    )
)
```

Generated event:

```json
{
  "_change_type":"update_postimage",
  "_commit_version":1002,
  "_commit_timestamp":"2026-08-05T08:10:00Z",
  "vehicle_id":"VOLVO001",
  "signal_id":"123",
  "value":60
}
```

---

## Publishing to Event Hubs

Event Hubs supports a Kafka-compatible endpoint.

Databricks can write directly using Structured Streaming.

```python
(
 events.writeStream
   .format("kafka")
   .option(
      "kafka.bootstrap.servers",
      "mynamespace.servicebus.windows.net:9093"
   )
   .option("topic","vehicle-signals")
   .option(
      "checkpointLocation",
      "abfss://checkpoints/cdf"
   )
   .start()
)
```

---

## Recommended Event Metadata

Add operational metadata to every event:

```json
{
  "event_id":"orders-12345-v1002",
  "source":"databricks",
  "catalog":"main",
  "schema":"sales",
  "table":"orders",
  "primary_key":"12345",
  "change_type":"update_postimage",
  "commit_version":1002,
  "commit_timestamp":"2026-08-05T08:10:00Z",
  "payload":{}
}
```

---

## Consumer Options

### Azure Functions

```text
Event Hub Trigger
```

### .NET Applications

```csharp
EventProcessorClient
```

### Fabric Eventstream

```text
Event Hub Source
```

### Spark Consumers

```python
spark.readStream.format("kafka")
```

### AKS Microservices

```text
Kafka Consumer
```

---

## Advantages

| Benefit | Description |
|----------|-------------|
| High Throughput | Millions of events/sec |
| Replay | Reprocess historical events |
| Partitioning | Scale consumers independently |
| Fan-out | Multiple subscribers |
| Kafka Compatibility | Existing Kafka tooling |

---

## Limitations

| Limitation | Description |
|------------|-------------|
| No DLQ | Requires implementation |
| No Transactions | Event stream only |
| Ordering | Guaranteed only per partition |
| Consumer State | Managed by consumers |

---

# Pattern 2: Delta CDF → Azure Service Bus Topics

## Architecture

```text
Delta CDF
    │
    ▼
Databricks Publisher
    │
    ▼
Service Bus Topic
    │
 ┌──┼───────┬─────────┐
 ▼  ▼       ▼         ▼
ERP CRM Notifications Workflow
```

---

## When to Use

Recommended when:

- Enterprise applications consume events
- Reliable delivery is critical
- Business workflows are involved
- DLQ is required
- Duplicate detection is required

---

## Service Bus Benefits

### Dead Letter Queue

```text
Consumer Failure
      │
      ▼
DLQ
```

---

### Duplicate Detection

```text
event-id
```

Avoids processing duplicate events.

---

### Transactions

```text
Receive Message
Update Database
Complete Message
```

---

### Sessions

```text
vehicle-1
vehicle-2
vehicle-3
```

Maintains ordered processing per key.

---

## Publishing from Databricks

Typically implemented with `foreachBatch`.

```python
def publish(batch_df, batch_id):

    rows = batch_df.collect()

    for row in rows:

        payload = {
            "vehicle_id": row.vehicle_id,
            "change_type": row._change_type,
            "version": row._commit_version
        }

        servicebus_client.send_messages(
            ServiceBusMessage(
                json.dumps(payload)
            )
        )
```

```python
(
 cdf.writeStream
    .foreachBatch(publish)
    .start()
)
```

---

## Topic Design

Topic:

```text
vehicle-changes
```

Subscriptions:

```text
analytics
search-index
crm
notifications
maintenance-alerts
```

Each subscription receives its own copy.

---

## Subscription Filters

Example:

```sql
change_type='delete'
```

or

```sql
vehicle_type='truck'
```

Service Bus routes automatically.

---

## Advantages

| Benefit | Description |
|----------|-------------|
| DLQ | Native support |
| Transactions | Supported |
| Duplicate Detection | Supported |
| Sessions | Ordered processing |
| Routing | Subscription filters |

---

## Limitations

| Limitation | Description |
|------------|-------------|
| Throughput | Lower than Event Hubs |
| Cost | Higher per message |
| Replay | Not designed as event store |

---

# Pattern 3: Delta CDF → Event Grid

## Architecture

```text
Delta Change
      │
      ▼
Event Grid
      │
 ┌────┼───────┬─────┐
 ▼    ▼       ▼     ▼
Logic App Function Power Automate
```

---

## When to Use

Use only when consumers need:

```text
Something changed
```

Not:

```text
Give me every changed row
```

---

## Example Event

```json
{
  "table":"vehicle_signals",
  "version":1002,
  "changeCount":350
}
```

---

## Typical Subscribers

- Azure Functions
- Logic Apps
- Power Automate
- Automation workflows

---

## Advantages

| Benefit | Description |
|----------|-------------|
| Simple | Easy integration |
| Fan-out | Native event routing |
| Serverless | Minimal infrastructure |

---

## Limitations

| Limitation | Description |
|------------|-------------|
| Not Replayable | Limited retention |
| Small Payloads | Not intended for large data |
| Not a Stream | Notification service only |

---

# Recommended Enterprise Architecture

For large-scale Azure Databricks environments:

```text
Delta Tables
      │
      ▼
Change Data Feed
      │
      ▼
Structured Streaming Publisher
      │
      ▼
Event Hubs
      │
      ├── Fabric
      ├── Search Index
      ├── AI Applications
      ├── Real-Time Analytics
      └── Operational Services

                    +
      ▼
Service Bus Topics
      │
      ├── CRM
      ├── ERP
      ├── Notifications
      └── Business Workflows
```

---

# Hybrid Enterprise Pattern

A common enterprise architecture is:

```text
Delta CDF
    │
    ▼
Azure Event Hubs
    │
    ▼
Azure Function
    │
    ▼
Azure Service Bus Topics
```

This creates:

### Event Streaming Layer

```text
Event Hubs
```

Provides:

- High throughput
- Replay
- Analytics
- Fabric integration

### Business Messaging Layer

```text
Service Bus
```

Provides:

- DLQ
- Routing
- Transactions
- Workflow orchestration

---

# Design Recommendations

## Event Envelope

Always publish:

```json
{
  "event_id":"",
  "table":"",
  "primary_key":"",
  "change_type":"",
  "commit_version":"",
  "commit_timestamp":"",
  "payload":{}
}
```

---

## Idempotency

Generate event IDs using:

```text
table
+
primary_key
+
commit_version
+
change_type
```

Example:

```text
orders-12345-v1002-update
```

---

## Checkpointing

Use Structured Streaming checkpoints:

```python
.option(
  "checkpointLocation",
  "abfss://checkpoints/cdf"
)
```

---

## Replay Strategy

Retain:

- Delta history
- CDF retention
- Event Hub retention

For long-term replay:

```text
CDF
    ▼
Archive Delta Table
```

---

# Final Recommendation

| Scenario | Recommended Pattern |
|-----------|---------------------|
| Real-time analytics | Event Hubs |
| Fabric integration | Event Hubs |
| Search indexing | Event Hubs |
| AI applications | Event Hubs |
| Enterprise applications | Service Bus |
| Workflow orchestration | Service Bus |
| Notifications | Event Grid |
| Power Automate | Event Grid |
| Hybrid enterprise platform | Event Hubs + Service Bus |

For most enterprise Azure Databricks platforms, the preferred architecture is:

```text
Delta CDF
     │
     ▼
Structured Streaming Publisher
     │
     ▼
Azure Event Hubs
     │
     ▼
Azure Service Bus (optional)
```

This provides scalable streaming, replay capability, enterprise messaging, and support for both analytics and operational workloads while maintaining Delta CDF as the authoritative source of change events.