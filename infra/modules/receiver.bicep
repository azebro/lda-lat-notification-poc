param functionAppName string
param functionPlanName string
param functionIdentityResourceId string
param functionIdentityClientId string
param functionStorageAccountName string
param deploymentContainerName string
param auditStorageAccountName string
param auditContainerName string
param eventHubNamespaceName string
param eventHubName string
param consumerGroupName string
param applicationInsightsName string
param maximumInstanceCount int = 10
param location string = resourceGroup().location
param tags object = {}

resource functionStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: functionStorageAccountName
}

resource auditStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: auditStorageAccountName
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: applicationInsightsName
}

module functionPlan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'function-flex-plan'
  params: {
    name: functionPlanName
    location: location
    tags: tags
    reserved: true
    skuName: 'FC1'
  }
}

module functionApp 'br/public:avm/res/web/site:0.22.0' = {
  name: 'function-app'
  params: {
    name: functionAppName
    location: location
    kind: 'functionapp,linux'
    tags: union(tags, {
      'azd-service-name': 'receiver'
    })
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    serverFarmResourceId: functionPlan.outputs.resourceId
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [
        functionIdentityResourceId
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${functionStorage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: functionIdentityResourceId
          }
        }
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
      scaleAndConcurrency: {
        alwaysReady: []
        instanceMemoryMB: 2048
        maximumInstanceCount: maximumInstanceCount
      }
    }
    configs: [
      {
        name: 'appsettings'
        storageAccountResourceId: functionStorage.id
        storageAccountUseIdentityAuthentication: true
        properties: {
          APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${functionIdentityClientId};Authorization=AAD'
          APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsights.properties.ConnectionString
          AUDIT_STORAGE_BLOB_SERVICE_URI: auditStorage.properties.primaryEndpoints.blob
          AUDIT_STORAGE_CONTAINER_NAME: auditContainerName
          AzureWebJobsStorage__blobServiceUri: functionStorage.properties.primaryEndpoints.blob
          AzureWebJobsStorage__clientId: functionIdentityClientId
          AzureWebJobsStorage__credential: 'managedidentity'
          AzureWebJobsStorage__queueServiceUri: functionStorage.properties.primaryEndpoints.queue
          AzureWebJobsStorage__tableServiceUri: functionStorage.properties.primaryEndpoints.table
          EventHubConnection__clientId: functionIdentityClientId
          EventHubConnection__credential: 'managedidentity'
          EventHubConnection__fullyQualifiedNamespace: '${eventHubNamespaceName}.servicebus.windows.net'
          EVENT_HUB_CONSUMER_GROUP: consumerGroupName
          EVENT_HUB_NAME: eventHubName
        }
      }
    ]
  }
}

output functionAppName string = functionApp.outputs.name
output functionAppResourceId string = functionApp.outputs.resourceId
output functionAppUrl string = 'https://${functionApp.outputs.defaultHostname}'