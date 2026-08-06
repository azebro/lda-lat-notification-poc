param logAnalyticsWorkspaceName string
param applicationInsightsName string
param location string = resourceGroup().location
param tags object = {}

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'log-analytics'
  params: {
    name: logAnalyticsWorkspaceName
    location: location
    tags: tags
    dataRetention: 30
  }
}

module applicationInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'application-insights'
  params: {
    name: applicationInsightsName
    location: location
    tags: tags
    applicationType: 'web'
    disableLocalAuth: true
    workspaceResourceId: logAnalytics.outputs.resourceId
  }
}

output applicationInsightsName string = applicationInsights.outputs.name
output applicationInsightsConnectionString string = applicationInsights.outputs.connectionString
output applicationInsightsResourceId string = applicationInsights.outputs.resourceId
output logAnalyticsWorkspaceName string = logAnalytics.outputs.name
output logAnalyticsWorkspaceId string = logAnalytics.outputs.logAnalyticsWorkspaceId
output logAnalyticsWorkspaceResourceId string = logAnalytics.outputs.resourceId