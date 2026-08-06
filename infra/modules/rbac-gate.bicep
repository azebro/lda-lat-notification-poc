param storageAccountName string
param containerName string
param functionIdentityResourceId string
param location string = resourceGroup().location
param tags object = {}

#disable-next-line BCP081
module capabilityGate 'br/public:avm/res/resources/deployment-script:0.5.2' = {
  name: 'function-storage-capability-gate'
  params: {
    name: 'ds-function-storage-${uniqueString(storageAccountName, containerName)}'
    kind: 'AzureCLI'
    azCliVersion: '2.67.0'
    cleanupPreference: 'Always'
    location: location
    managedIdentities: {
      userAssignedResourceIds: [
        functionIdentityResourceId
      ]
    }
    retentionInterval: 'PT1H'
    runOnce: false
    tags: tags
    timeout: 'PT15M'
    environmentVariables: [
      {
        name: 'STORAGE_ACCOUNT_NAME'
        value: storageAccountName
      }
      {
        name: 'CONTAINER_NAME'
        value: containerName
      }
    ]
    scriptContent: '''
      #!/bin/bash
      set -euo pipefail

      delay=5
      for attempt in $(seq 1 20); do
        if az storage blob list \
          --account-name "$STORAGE_ACCOUNT_NAME" \
          --container-name "$CONTAINER_NAME" \
          --auth-mode login \
          --num-results 1 \
          --only-show-errors \
          --output none; then
          echo "Function identity can access deployment storage."
          exit 0
        fi

        echo "Storage RBAC not effective yet (attempt $attempt/20)."
        sleep "$delay"
        if [ "$delay" -lt 30 ]; then
          delay=$((delay + 5))
        fi
      done

      echo "Timed out waiting for Function identity access to deployment storage." >&2
      exit 1
    '''
  }
}

output name string = capabilityGate.outputs.name