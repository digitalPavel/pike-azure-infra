// PostgreSQL Flexible Server — shared database for the Container Apps.
// The admin user is created here. A DML-only app user is typically created by the
// migrate job (Phase 4), not in Bicep, so its password never reaches the runtime apps.

@description('Server name — globally unique.')
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Initial database name.')
param databaseName string = 'appdb'

@description('Administrator login.')
param administratorLogin string

@secure() // tells Bicep this is sensitive — never logged or shown in outputs
param administratorPassword string

@allowed(['Burstable', 'GeneralPurpose', 'MemoryOptimized'])
param tier string = 'Burstable'

@description('Compute SKU, e.g. Standard_B1ms.')
param skuName string = 'Standard_B1ms'

@allowed(['14', '15', '16'])
param postgresVersion string = '16'

@description('Storage size in GB.')
param storageSizeGB int = 32

@description('Backup retention in days.')
param backupRetentionDays int = 7

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: tier
  }
  properties: {
    version: postgresVersion
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    storage: {
      storageSizeGB: storageSizeGB
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
  }
}

// Allows Container Apps egress to reach the DB. Narrow to the CAE static outbound IP
// once assigned for tighter security.
resource firewallAllowAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: server
  name: 'AllowAllAzureServicesAndResourcesWithinAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

@description('Resource ID of the server.')
output id string = server.id

@description('Server name.')
output name string = server.name

@description('Fully qualified domain name of the server.')
output fullyQualifiedDomainName string = server.properties.fullyQualifiedDomainName

@description('Database name.')
output databaseName string = database.name
