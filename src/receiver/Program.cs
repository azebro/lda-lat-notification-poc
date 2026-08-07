using Azure.Core;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.Exporter;
using Azure.Storage.Blobs;
using DeltaNotificationReceiver.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Azure.Functions.Worker.OpenTelemetry;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenTelemetry;

var builder = FunctionsApplication.CreateBuilder(args);

var managedIdentityClientId = builder.Configuration["EventHubConnection__clientId"];
TokenCredential credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
{
    ManagedIdentityClientId = managedIdentityClientId
});

builder.Services.AddOpenTelemetry()
    .UseFunctionsWorkerDefaults()
    .UseAzureMonitorExporter(options => options.Credential = credential);

builder.Services.AddSingleton(serviceProvider =>
{
    var configuration = serviceProvider.GetRequiredService<IConfiguration>();
    var serviceUri = configuration["AUDIT_STORAGE_BLOB_SERVICE_URI"]
        ?? throw new InvalidOperationException("AUDIT_STORAGE_BLOB_SERVICE_URI is required.");
    return new BlobServiceClient(new Uri(serviceUri), credential);
});
builder.Services.AddSingleton<IAuditBlobStore, AzureAuditBlobStore>();
builder.Services.AddSingleton<IAuditWriter, BlobAuditWriter>();
builder.Services.AddSingleton<DeltaChangeProcessor>();

builder.Build().Run();
