// Container Apps Environment — shared runtime host for the Container Apps and any jobs.
// listKeys() is called here rather than passed as a parameter so the Log Analytics
// shared key never surfaces as a module output in deployment history.

@description('Environment name.')
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Resource ID of the Log Analytics workspace for app logs.')
param logAnalyticsWorkspaceId string

@description('Customer (GUID) ID of the Log Analytics workspace.')
param logAnalyticsCustomerId string

// Retrieve the workspace by name (extracted from the full resource ID) so we can
// call listKeys() on it — Bicep requires a resource object, not a plain string.
resource laws 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(logAnalyticsWorkspaceId, '/'))
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: laws.listKeys().primarySharedKey
      }
    }
  }
}

@description('Resource ID of the environment.')
output environmentId string = environment.id

@description('Default domain — Container App FQDNs follow <appName>.<defaultDomain>.')
output defaultDomain string = environment.properties.defaultDomain
