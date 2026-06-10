// Generic one-shot migration job — Container Apps Job, manual trigger.
// Runs a migration entrypoint inside the app image with elevated DB credentials.
// `command`, `env`, and `secrets` are authored by the caller, so any migration tool
// works (Prisma `node migrate.mjs`, Drizzle `tsx migrate.ts`, Alembic, etc.).
// Triggered via: az containerapp job start -n <name> -g <rg>
//
// Admin/elevated credentials stay on this job only — they never reach the running apps.

@description('Job name.')
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Resource ID of the Container Apps Environment.')
param containerAppsEnvironmentId string

@description('ACR login server, e.g. myacr.azurecr.io.')
param containerRegistryLoginServer string

@description('Full image reference — usually the app image, different entrypoint.')
param image string

@description('Resource ID of the user-assigned managed identity granted AcrPull.')
param userAssignedIdentityId string

@description('Entrypoint command (overrides image ENTRYPOINT), e.g. [\'node_modules/.bin/tsx\'] or [\'node\', \'/app/scripts/migrate.mjs\'].')
param command array

@description('Optional args (overrides image CMD), e.g. [\'backend/src/db/migrate.ts\']. Empty = none.')
param args array = []

@description('Environment variables — { name, value } and/or { name, secretRef } items.')
param env array = []

@description('Secret name -> value map for the job (e.g. admin DATABASE_URL).')
@secure()
param secrets object = {}

@description('CPU cores.')
param cpu string = '0.5'

@description('Memory.')
param memory string = '1Gi'

@description('Replica timeout in seconds — covers cold image pull + migration.')
param replicaTimeout int = 600

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    environmentId: containerAppsEnvironmentId
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: replicaTimeout
      // No retries — migration must be idempotent; a retry could mask a partial
      // failure. Fail fast and let the operator inspect logs.
      replicaRetryLimit: 0
      registries: [
        {
          server: containerRegistryLoginServer
          identity: userAssignedIdentityId
        }
      ]
      // The `secrets` param is @secure; the linter just can't track security
      // through the items() loop, so the value is suppressed here intentionally.
      secrets: [for s in items(secrets): {
        name: s.key
        #disable-next-line use-secure-value-for-secure-inputs
        value: s.value
      }]
    }
    template: {
      containers: [
        {
          name: 'migrate'
          image: image
          command: command
          args: empty(args) ? null : args
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: env
        }
      ]
    }
  }
}

@description('Job name — pass to az containerapp job start.')
output name string = job.name
