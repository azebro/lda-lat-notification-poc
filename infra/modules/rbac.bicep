param accessConnectorPrincipalId string
param functionIdentityPrincipalId string
param verifierPrincipalId string
param dataLakeStorageAccountName string
param functionStorageAccountName string
param auditStorageAccountName string
param auditContainerName string
param eventHubNamespaceName string
param eventHubName string
param applicationInsightsName string
param logAnalyticsWorkspaceName string

var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var eventHubsDataSenderRoleId = '2b629674-e913-4c01-ae53-ef4638d8f975'
var eventHubsDataReceiverRoleId = 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'

resource dataLake 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: dataLakeStorageAccountName
}

resource functionStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: functionStorageAccountName
}

resource auditStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: auditStorageAccountName
}

resource auditBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: auditStorage
  name: 'default'
}

resource auditContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: auditBlobService
  name: auditContainerName
}

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: eventHubNamespaceName
}

resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' existing = {
  parent: eventHubNamespace
  name: eventHubName
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: applicationInsightsName
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource connectorDataLakeRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataLake.id, accessConnectorPrincipalId, storageBlobDataContributorRoleId)
  scope: dataLake
  properties: {
    principalId: accessConnectorPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
  }
}

resource connectorEventHubSenderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(eventHub.id, accessConnectorPrincipalId, eventHubsDataSenderRoleId)
  scope: eventHub
  properties: {
    principalId: accessConnectorPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataSenderRoleId)
  }
}

resource functionEventHubReceiverRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(eventHub.id, functionIdentityPrincipalId, eventHubsDataReceiverRoleId)
  scope: eventHub
  properties: {
    principalId: functionIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataReceiverRoleId)
  }
}

resource functionStorageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionStorage.id, functionIdentityPrincipalId, storageBlobDataOwnerRoleId)
  scope: functionStorage
  properties: {
    principalId: functionIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
  }
}

resource functionStorageQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionStorage.id, functionIdentityPrincipalId, storageQueueDataContributorRoleId)
  scope: functionStorage
  properties: {
    principalId: functionIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
  }
}

resource functionStorageTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionStorage.id, functionIdentityPrincipalId, storageTableDataContributorRoleId)
  scope: functionStorage
  properties: {
    principalId: functionIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
  }
}

resource functionAuditWriterRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(auditContainer.id, functionIdentityPrincipalId, storageBlobDataContributorRoleId)
  scope: auditContainer
  properties: {
    principalId: functionIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
  }
}

resource functionMetricsPublisherRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(applicationInsights.id, functionIdentityPrincipalId, monitoringMetricsPublisherRoleId)
  scope: applicationInsights
  properties: {
    principalId: functionIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
  }
}

resource verifierAuditReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(auditContainer.id, verifierPrincipalId, storageBlobDataReaderRoleId)
  scope: auditContainer
  properties: {
    principalId: verifierPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
  }
}

resource verifierLogReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalytics.id, verifierPrincipalId, logAnalyticsReaderRoleId)
  scope: logAnalytics
  properties: {
    principalId: verifierPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
  }
}

output roleAssignmentCount int = 9