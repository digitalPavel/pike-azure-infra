// Generic Container App — one container, external HTTP ingress, user-assigned MI for ACR pull.
// Consolidates the per-app modules from the source projects (Flask on 8000, Next.js on 3000,
// EasyAuth-gated apps). `env` and `secrets` are authored by the caller (the profile main.bicep),
// so any app shape is supported without editing this module.
//
//   - env:     array of { name, value } and/or { name, secretRef } items, passed through verbatim.
//   - secrets: name->value map; each becomes a Container App secret referenced by env secretRef.
//              Marked @secure so values never appear in deployment history.
//   - probePath: empty disables probes; non-empty adds Startup + Liveness HTTP probes on it.
//   - authMode: 'easyauth' adds a platform authConfig (Entra ID); 'none'/'nextauth' add nothing
//              (NextAuth is implemented purely via env + secrets inside the app).

@description('Container App name.')
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Resource ID of the Container Apps Environment.')
param containerAppsEnvironmentId string

@description('ACR login server, e.g. myacr.azurecr.io.')
param containerRegistryLoginServer string

@description('Resource ID of the user-assigned managed identity granted AcrPull.')
param userAssignedIdentityId string

@description('Full image reference: <acr>.azurecr.io/<repo>:<tag>.')
param image string

@description('Container listening port — also the ingress target port.')
param port int

@description('Environment variables — { name, value } and/or { name, secretRef } items.')
param env array = []

@description('Secret name -> value map. Injected as Container App secrets and referenced via env secretRef.')
@secure()
param secrets object = {}

@description('HTTP probe path, e.g. /health. Empty disables probes.')
param probePath string = ''

@description('CPU cores per replica.')
param cpu string = '0.5'

@description('Memory per replica.')
param memory string = '1Gi'

@description('Minimum replica count.')
param minReplicas int = 1

@description('Maximum replica count.')
param maxReplicas int = 1

@description('Optional entrypoint override. Empty uses the image CMD.')
param command array = []

@description('Authentication mode. easyauth adds a platform authConfig (Entra ID).')
@allowed(['none', 'nextauth', 'easyauth'])
param authMode string = 'none'

@description('Entra ID app registration client ID. Required when authMode = easyauth.')
param entraClientId string = ''

@description('Entra ID tenant ID. Used when authMode = easyauth.')
param entraTenantId string = '9fbce44f-d64c-4f7e-bbe0-19479c36278b'

@description('Custom domain to bind, e.g. assets.pike.com. Empty = default ACA URL only. The CNAME + asuid TXT records must already exist in DNS before deploying with this set.')
param customDomain string = ''

@description('Resource ID of an existing certificate to bind. Empty = create a free ACA managed certificate for customDomain.')
param customDomainCertificateId string = ''

// Create a free managed cert only when a custom domain is set and no BYO cert is supplied.
var createManagedCert = customDomain != '' && customDomainCertificateId == ''
var effectiveCertId = customDomainCertificateId != '' ? customDomainCertificateId : (createManagedCert ? managedCert!.id : '')

// Bind the custom domain on ingress only when one is provided.
var ingressCustomDomains = customDomain != '' ? [
  {
    name: customDomain
    bindingType: 'SniEnabled'
    certificateId: effectiveCertId
  }
] : []

// Startup probe allows a long warm-up (image pull + framework + background init);
// Liveness restarts the container if the path stops responding.
var probes = empty(probePath) ? [] : [
  {
    type: 'Startup'
    httpGet: {
      path: probePath
      port: port
    }
    initialDelaySeconds: 10
    periodSeconds: 10
    failureThreshold: 30
  }
  {
    type: 'Liveness'
    httpGet: {
      path: probePath
      port: port
    }
    periodSeconds: 30
    failureThreshold: 3
  }
]

// Managed certificates live on the environment. Resolve it by name (from the ID)
// so we can create one as a child. Validation (CNAME) runs at deploy time, so the
// DNS records must already exist — otherwise this resource fails.
resource cae 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: last(split(containerAppsEnvironmentId, '/'))
}

resource managedCert 'Microsoft.App/managedEnvironments/managedCertificates@2024-03-01' = if (createManagedCert) {
  parent: cae
  name: '${name}-cert'
  location: location
  properties: {
    subjectName: customDomain
    domainControlValidation: 'CNAME'
  }
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
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
    managedEnvironmentId: containerAppsEnvironmentId
    configuration: {
      ingress: {
        external: true
        targetPort: port
        transport: 'http'
        customDomains: ingressCustomDomains
      }
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
          name: name
          image: image
          command: empty(command) ? null : command
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: env
          probes: probes
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
}

// EasyAuth (Container Apps built-in auth). Apply after IT provisions the Entra app
// registration. The redirect URI to give IT:
//   https://<name>.<caeDefaultDomain>/.auth/login/aad/callback
// The client secret must be present in `secrets` as 'microsoft-provider-authentication-secret'.
resource authConfig 'Microsoft.App/containerApps/authConfigs@2024-03-01' = if (authMode == 'easyauth') {
  parent: containerApp
  name: 'current'
  properties: {
    globalValidation: {
      redirectToProvider: 'azureactivedirectory'
      unauthenticatedClientAction: 'RedirectToLoginPage'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: entraClientId
          clientSecretSettingName: 'microsoft-provider-authentication-secret'
          // Commercial Azure only; environment() is unnecessary for Pike's single cloud.
          #disable-next-line no-hardcoded-env-urls
          openIdIssuer: 'https://login.microsoftonline.com/${entraTenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            'api://${entraClientId}'
            entraClientId
          ]
        }
      }
    }
    platform: {
      enabled: true
    }
  }
}

@description('Public FQDN of the Container App.')
output fqdn string = containerApp.properties.configuration.ingress.fqdn
