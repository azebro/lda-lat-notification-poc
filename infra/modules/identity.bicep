@description('Name of the Function user-assigned managed identity.')
param name string

param location string = resourceGroup().location
param tags object = {}

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'function-user-assigned-identity'
  params: {
    name: name
    location: location
    tags: tags
  }
}

output clientId string = identity.outputs.clientId
output principalId string = identity.outputs.principalId
output resourceId string = identity.outputs.resourceId