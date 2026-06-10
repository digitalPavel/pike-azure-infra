// Azure Container Registry — stores the app's Docker images.
// Admin user is disabled; Container Apps pull via a user-assigned managed identity
// granted AcrPull (see appIdentity.bicep), so no registry credentials exist.

@description('Registry name — alphanumeric only, globally unique.')
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Registry SKU.')
@allowed(['Basic', 'Standard', 'Premium'])
param sku string = 'Basic'

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    adminUserEnabled: false
  }
}

@description('Resource ID of the registry.')
output id string = registry.id

@description('Registry name (without domain).')
output name string = registry.name

@description('Login server, e.g. myacr.azurecr.io.')
output loginServer string = registry.properties.loginServer
