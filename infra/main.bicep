targetScope = 'subscription'

@minLength(1)
@maxLength(20)
@description('Azure Developer CLI environment name used for deterministic resource naming.')
param environmentName string

@metadata({
  azd: {
    type: 'location'
  }
})
@description('Azure region for all POC-owned resources.')
param location string

@description('Optional resource group name override.')
param resourceGroupName string = ''

@minLength(3)
@maxLength(13)
@description('Globally unique lowercase alphanumeric token used in Azure resource names.')
param nameToken string = take(toLower(uniqueString(subscription().id, environmentName, location)), 8)

@allowed([
  'premium'
])
@description('Azure Databricks workspace SKU. Premium is required by the approved POC architecture.')
param databricksWorkspaceSku string = 'premium'

@description('Default Databricks job-cluster node type passed to Phase 4 as a deployment output.')
param databricksNodeType string = 'Standard_D4ds_v6'

@description('Additional resource tags merged with the required POC ownership tags.')
param tags object = {}

@description('Principal that reads audit evidence and Log Analytics. Defaults to the deploying principal.')
param verifierPrincipalId string = deployer().objectId

@description('Maximum Flex Consumption instance count for the POC receiver.')
@minValue(1)
@maxValue(100)
param functionMaximumInstanceCount int = 10

var rgName = !empty(resourceGroupName) ? resourceGroupName : 'rg-delta-notify-${environmentName}-${nameToken}'
var requiredTags = {
  environment: environmentName
  workload: 'delta-change-notification-poc'
  managedBy: 'azd-bicep'
  ownershipToken: nameToken
}
var allTags = union(tags, requiredTags)

var names = {
  accessConnector: 'dac-delta-${nameToken}'
  applicationInsights: 'appi-delta-${nameToken}'
  auditStorage: 'st${nameToken}audit'
  dataLakeStorage: 'st${nameToken}lake'
  databricksWorkspace: 'dbw-delta-${nameToken}'
  eventHub: 'delta-changes'
  eventHubNamespace: 'evhns-delta-${nameToken}'
  functionApp: 'func-delta-${nameToken}'
  functionHostStorage: 'st${nameToken}func'
  functionIdentity: 'id-delta-${nameToken}'
  functionPlan: 'plan-delta-${nameToken}'
  logAnalytics: 'log-delta-${nameToken}'
}

var deploymentContainerName = 'app-package-${nameToken}'
var dataContainerName = 'poc'
var auditContainerName = 'delta-change-audit'
var consumerGroupName = 'notification-receiver'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: allTags
}

module identity 'modules/identity.bicep' = {
  name: 'function-identity'
  scope: resourceGroup
  params: {
    name: names.functionIdentity
    location: location
    tags: allTags
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  scope: resourceGroup
  params: {
    auditContainerName: auditContainerName
    auditStorageAccountName: names.auditStorage
    dataContainerName: dataContainerName
    dataLakeStorageAccountName: names.dataLakeStorage
    deploymentContainerName: deploymentContainerName
    functionStorageAccountName: names.functionHostStorage
    location: location
    tags: allTags
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: resourceGroup
  params: {
    applicationInsightsName: names.applicationInsights
    location: location
    logAnalyticsWorkspaceName: names.logAnalytics
    tags: allTags
  }
}

module messaging 'modules/messaging.bicep' = {
  name: 'messaging'
  scope: resourceGroup
  params: {
    consumerGroupName: consumerGroupName
    eventHubName: names.eventHub
    location: location
    namespaceName: names.eventHubNamespace
    tags: allTags
  }
}

module databricks 'modules/databricks.bicep' = {
  name: 'databricks'
  scope: resourceGroup
  params: {
    accessConnectorName: names.accessConnector
    workspaceSku: databricksWorkspaceSku
    location: location
    tags: allTags
    workspaceName: names.databricksWorkspace
  }
}

module rbac 'modules/rbac.bicep' = {
  name: 'rbac'
  scope: resourceGroup
  params: {
    accessConnectorPrincipalId: databricks.outputs.accessConnectorPrincipalId
    applicationInsightsName: names.applicationInsights
    auditContainerName: auditContainerName
    auditStorageAccountName: names.auditStorage
    dataLakeStorageAccountName: names.dataLakeStorage
    eventHubName: names.eventHub
    eventHubNamespaceName: names.eventHubNamespace
    functionIdentityPrincipalId: identity.outputs.principalId
    functionStorageAccountName: names.functionHostStorage
    logAnalyticsWorkspaceName: names.logAnalytics
    verifierPrincipalId: verifierPrincipalId
  }
  dependsOn: [
    monitoring
    messaging
    storage
  ]
}

module rbacPropagationGate 'modules/rbac-gate.bicep' = {
  name: 'rbac-propagation-gate'
  scope: resourceGroup
  params: {
    containerName: deploymentContainerName
    functionIdentityResourceId: identity.outputs.resourceId
    location: location
    storageAccountName: names.functionHostStorage
    tags: allTags
  }
  dependsOn: [
    rbac
  ]
}

module receiver 'modules/receiver.bicep' = {
  name: 'receiver'
  scope: resourceGroup
  params: {
    applicationInsightsName: names.applicationInsights
    auditContainerName: auditContainerName
    auditStorageAccountName: names.auditStorage
    consumerGroupName: consumerGroupName
    deploymentContainerName: deploymentContainerName
    eventHubName: names.eventHub
    eventHubNamespaceName: names.eventHubNamespace
    functionAppName: names.functionApp
    functionIdentityClientId: identity.outputs.clientId
    functionIdentityResourceId: identity.outputs.resourceId
    functionPlanName: names.functionPlan
    functionStorageAccountName: names.functionHostStorage
    location: location
    maximumInstanceCount: functionMaximumInstanceCount
    tags: allTags
  }
  dependsOn: [
    rbacPropagationGate
  ]
}

output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP_NAME string = resourceGroup.name
output AZURE_SUBSCRIPTION_ID string = subscription().subscriptionId
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_NAME_TOKEN string = nameToken
output AZURE_DATABRICKS_ACCESS_CONNECTOR_ID string = databricks.outputs.accessConnectorResourceId
output AZURE_DATABRICKS_ACCESS_CONNECTOR_PRINCIPAL_ID string = databricks.outputs.accessConnectorPrincipalId
output AZURE_DATABRICKS_NODE_TYPE string = databricksNodeType
output AZURE_DATABRICKS_WORKSPACE_ID string = databricks.outputs.workspaceId
output AZURE_DATABRICKS_WORKSPACE_RESOURCE_ID string = databricks.outputs.workspaceResourceId
output AZURE_DATABRICKS_WORKSPACE_NAME string = databricks.outputs.workspaceName
output AZURE_DATABRICKS_WORKSPACE_URL string = databricks.outputs.workspaceUrl
output AZURE_DATA_LAKE_ACCOUNT_NAME string = storage.outputs.dataLakeStorageAccountName
output AZURE_DATA_LAKE_CONTAINER_NAME string = dataContainerName
output AZURE_EVENT_HUB_NAME string = names.eventHub
output AZURE_EVENT_HUB_CONSUMER_GROUP string = consumerGroupName
output AZURE_EVENT_HUB_NAMESPACE_FQDN string = '${names.eventHubNamespace}.servicebus.windows.net'
output AZURE_EVENT_HUB_NAMESPACE_NAME string = names.eventHubNamespace
output AZURE_FUNCTION_APP_NAME string = receiver.outputs.functionAppName
output AZURE_FUNCTION_HOST_STORAGE_ACCOUNT_NAME string = names.functionHostStorage
output AZURE_FUNCTION_IDENTITY_CLIENT_ID string = identity.outputs.clientId
output AZURE_AUDIT_STORAGE_ACCOUNT_NAME string = names.auditStorage
output AZURE_AUDIT_CONTAINER_NAME string = auditContainerName
output AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING string = monitoring.outputs.applicationInsightsConnectionString
output AZURE_APPLICATION_INSIGHTS_NAME string = monitoring.outputs.applicationInsightsName
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = monitoring.outputs.logAnalyticsWorkspaceId
output AZURE_LOG_ANALYTICS_WORKSPACE_NAME string = monitoring.outputs.logAnalyticsWorkspaceName