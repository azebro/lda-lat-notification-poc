param workspaceName string
param accessConnectorName string
param workspaceSku string = 'premium'
param location string = resourceGroup().location
param tags object = {}

module accessConnector 'br/public:avm/res/databricks/access-connector:0.4.3' = {
  name: 'databricks-access-connector'
  params: {
    name: accessConnectorName
    location: location
    tags: tags
    managedIdentities: {
      systemAssigned: true
    }
  }
}

module workspace 'br/public:avm/res/databricks/workspace:0.12.0' = {
  name: 'databricks-workspace'
  params: {
    name: workspaceName
    location: location
    tags: tags
    accessConnectorResourceId: accessConnector.outputs.resourceId
    publicNetworkAccess: 'Enabled'
    skuName: workspaceSku
  }
}

output accessConnectorPrincipalId string = accessConnector.outputs.?systemAssignedMIPrincipalId ?? ''
output accessConnectorResourceId string = accessConnector.outputs.resourceId
@description('Numeric Azure Databricks control-plane workspace ID.')
output workspaceId string = workspace.outputs.workspaceResourceId ?? ''
output workspaceName string = workspace.outputs.name
output workspaceResourceId string = workspace.outputs.resourceId
output workspaceUrl string = workspace.outputs.workspaceUrl ?? ''