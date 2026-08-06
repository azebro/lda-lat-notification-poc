param namespaceName string
param eventHubName string
param consumerGroupName string
param location string = resourceGroup().location
param tags object = {}

module eventHubs 'br/public:avm/res/event-hub/namespace:0.15.0' = {
  name: 'event-hubs'
  params: {
    name: namespaceName
    location: location
    tags: tags
    disableLocalAuth: true
    kafkaEnabled: true
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    skuCapacity: 1
    skuName: 'Standard'
    eventhubs: [
      {
        name: eventHubName
        partitionCount: 2
        messageRetentionInDays: 1
        status: 'Active'
        consumergroups: [
          {
            name: consumerGroupName
          }
        ]
      }
    ]
  }
}

output eventHubName string = eventHubName
output eventHubResourceId string = resourceId('Microsoft.EventHub/namespaces/eventhubs', namespaceName, eventHubName)
output namespaceName string = eventHubs.outputs.name
output namespaceResourceId string = eventHubs.outputs.resourceId