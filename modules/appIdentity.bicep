// Generic user-assigned managed identity + AcrPull role assignment.
// One per workload (each app, plus the migrate job) so AcrPull can be assigned in
// Phase 1 and propagated during the 60s sleep before any image pull. Identities are
// created unconditionally (not gated on deployApps) so the role assignment exists
// and propagates before Phase 2 (build + push).

@description('Identity name.')
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Resource ID of the ACR — role assignment is scoped to this registry only.')
param acrId string

@description('Name of the ACR (used to resolve the existing resource for scoping).')
param acrName string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

resource acrResource 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// AcrPull built-in role: 7f951dda-4ed3-4680-a7ca-43fe172d538d
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // guid() args use stable resource IDs — not principalId, which isn't known at
  // deployment start and would change on every redeploy.
  name: guid(acrId, identity.id, 'acrpull')
  scope: acrResource
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    )
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Resource ID of the identity — assign to a Container App or job.')
output identityId string = identity.id

@description('Principal (object) ID of the identity.')
output principalId string = identity.properties.principalId
