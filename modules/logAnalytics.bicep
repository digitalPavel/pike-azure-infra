// Log Analytics Workspace — backing store for App Insights and Container Apps logs.
// primarySharedKey is intentionally NOT exposed as an output; the Container Apps
// Environment module reads it via listKeys() on an existing reference so the key
// never appears in deployment history.

@description('Workspace name.')
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Daily log retention in days.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

@description('Resource ID of the workspace.')
output workspaceId string = workspace.id

@description('Workspace customer (GUID) ID — used by the Container Apps Environment.')
output customerId string = workspace.properties.customerId
