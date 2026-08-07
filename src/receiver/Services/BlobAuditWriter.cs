using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using DeltaNotificationReceiver.Models;
using Microsoft.Extensions.Configuration;

namespace DeltaNotificationReceiver.Services;

public interface IAuditBlobStore
{
    Task UploadIfAbsentAsync(string blobPath, BinaryData content, CancellationToken cancellationToken);
}

public sealed class AzureAuditBlobStore : IAuditBlobStore
{
    private readonly BlobContainerClient _containerClient;

    public AzureAuditBlobStore(BlobServiceClient serviceClient, IConfiguration configuration)
    {
        var containerName = configuration["AUDIT_STORAGE_CONTAINER_NAME"]
            ?? throw new InvalidOperationException("AUDIT_STORAGE_CONTAINER_NAME is required.");
        _containerClient = serviceClient.GetBlobContainerClient(containerName);
    }

    public async Task UploadIfAbsentAsync(
        string blobPath,
        BinaryData content,
        CancellationToken cancellationToken)
    {
        var blobClient = _containerClient.GetBlobClient(blobPath);
        var options = new BlobUploadOptions
        {
            Conditions = new BlobRequestConditions { IfNoneMatch = ETag.All },
            HttpHeaders = new BlobHttpHeaders { ContentType = "application/json" }
        };

        await blobClient.UploadAsync(content, options, cancellationToken);
    }
}

public sealed class BlobAuditWriter(IAuditBlobStore blobStore) : IAuditWriter
{
    public async Task<AuditWriteResult> WriteAsync(
        DeltaChangeEnvelope envelope,
        BinaryData canonicalJson,
        CancellationToken cancellationToken)
    {
        try
        {
            await blobStore.UploadIfAbsentAsync(AuditPath.For(envelope), canonicalJson, cancellationToken);
            return AuditWriteResult.Created;
        }
        catch (RequestFailedException exception)
            when ((exception.Status == 409 && exception.ErrorCode == BlobErrorCode.BlobAlreadyExists)
                || (exception.Status == 412 && exception.ErrorCode == BlobErrorCode.ConditionNotMet))
        {
            return AuditWriteResult.Duplicate;
        }
    }
}