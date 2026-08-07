# Delta Notification Receiver

.NET 10 isolated Azure Function that consumes one Delta CDF envelope per Event Hubs invocation, validates the v1 contract, and conditionally creates an audit Blob.

Required application settings are provisioned by Bicep:

- `EventHubConnection__fullyQualifiedNamespace`, `EventHubConnection__credential`, and `EventHubConnection__clientId`
- `EVENT_HUB_NAME` and `EVENT_HUB_CONSUMER_GROUP`
- `AUDIT_STORAGE_BLOB_SERVICE_URI` and `AUDIT_STORAGE_CONTAINER_NAME`
- `APPLICATIONINSIGHTS_CONNECTION_STRING` and `APPLICATIONINSIGHTS_AUTHENTICATION_STRING`

Build locally with `dotnet build`. Azure-backed execution additionally requires local equivalents for the settings above and an authenticated identity with Event Hubs receiver and audit Blob contributor access.