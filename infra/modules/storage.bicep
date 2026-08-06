param dataLakeStorageAccountName string
param functionStorageAccountName string
param auditStorageAccountName string
param dataContainerName string
param deploymentContainerName string
param auditContainerName string
param location string = resourceGroup().location
param tags object = {}

var commonNetworkAcls = {
  bypass: 'AzureServices'
  defaultAction: 'Allow'
}

module dataLake 'br/public:avm/res/storage/storage-account:0.33.0' = {
  name: 'data-lake-storage'
  params: {
    name: dataLakeStorageAccountName
    location: location
    tags: tags
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    blobServices: {
      containers: [
        {
          name: dataContainerName
        }
      ]
    }
    defaultToOAuthAuthentication: true
    enableHierarchicalNamespace: true
    kind: 'StorageV2'
    minimumTlsVersion: 'TLS1_2'
    networkAcls: commonNetworkAcls
    publicNetworkAccess: 'Enabled'
    skuName: 'Standard_LRS'
  }
}

module functionStorage 'br/public:avm/res/storage/storage-account:0.33.0' = {
  name: 'function-host-storage'
  params: {
    name: functionStorageAccountName
    location: location
    tags: tags
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    blobServices: {
      containers: [
        {
          name: deploymentContainerName
        }
      ]
    }
    defaultToOAuthAuthentication: true
    kind: 'StorageV2'
    minimumTlsVersion: 'TLS1_2'
    networkAcls: commonNetworkAcls
    publicNetworkAccess: 'Enabled'
    skuName: 'Standard_LRS'
  }
}

module auditStorage 'br/public:avm/res/storage/storage-account:0.33.0' = {
  name: 'audit-storage'
  params: {
    name: auditStorageAccountName
    location: location
    tags: tags
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    blobServices: {
      containers: [
        {
          name: auditContainerName
        }
      ]
    }
    defaultToOAuthAuthentication: true
    kind: 'StorageV2'
    minimumTlsVersion: 'TLS1_2'
    networkAcls: commonNetworkAcls
    publicNetworkAccess: 'Enabled'
    skuName: 'Standard_LRS'
  }
}

output auditStorageAccountName string = auditStorage.outputs.name
output dataLakeStorageAccountName string = dataLake.outputs.name
output functionStorageAccountName string = functionStorage.outputs.name