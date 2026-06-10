// Application Insights (workspace-based) — telemetry for the Container Apps.
// The connection string is passed to containers via secretRef so SDK additions
// (OpenTelemetry for Python, applicationinsights for Node) light up custom
// telemetry without any Bicep change.

@description('Application Insights component name.')
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Resource ID of the backing Log Analytics workspace.')
param logAnalyticsWorkspaceId string

@description('Telemetry retention in days.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: name
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
    RetentionInDays: retentionInDays
  }
}

@description('Resource ID of the component.')
output id string = appInsights.id

@description('Connection string — inject into containers as a secret.')
output connectionString string = appInsights.properties.ConnectionString

@description('Instrumentation key (legacy SDKs).')
output instrumentationKey string = appInsights.properties.InstrumentationKey
