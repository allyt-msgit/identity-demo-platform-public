[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ServicePrincipalId,

    [Parameter(Mandatory = $false)]
    [string]$SynchronizationJobId,

    [Parameter(Mandatory = $false)]
    [string]$CustomScimNamespace = 'urn:ietf:params:scim:schemas:extension:hub:1.0:User'
)

$ErrorActionPreference = 'Stop'

# Hub extension lifecycle attributes to add to the provisioning schema
$lifecycleSourceAttributes = @(
    @{ SourceName = ('{0}:employeeHireDate' -f $CustomScimNamespace);      TargetAttribute = 'employeeHireDate' }
    @{ SourceName = ('{0}:employeeLeaveDateTime' -f $CustomScimNamespace); TargetAttribute = 'employeeLeaveDateTime' }
    @{ SourceName = ('{0}:usageLocation' -f $CustomScimNamespace);         TargetAttribute = 'usageLocation' }
)

function Initialize-GraphModules {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Host 'Installing Microsoft.Graph.Authentication for current user...'
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Microsoft.Graph.Authentication
}

function Resolve-SynchronizationJobId {
    param(
        [string]$ProvisioningServicePrincipalId,
        [AllowNull()][string]$JobId
    )

    if (-not [string]::IsNullOrWhiteSpace($JobId)) {
        return $JobId
    }

    $response = Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/beta/servicePrincipals/{0}/synchronization/jobs" -f $ProvisioningServicePrincipalId)
    if ($null -eq $response.value -or $response.value.Count -eq 0) {
        throw 'No synchronization jobs found for this provisioning app.'
    }

    return $response.value[0].id
}

function Get-SourceObjectDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$ObjectName
    )

    $objects = @($Directory.objects)
    if ($objects.Count -eq 0) {
        return $null
    }

    return $objects | Where-Object { $_.name -ieq $ObjectName } | Select-Object -First 1
}

function Invoke-DirectoryDiscover {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProvisioningServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$JobId,

        [Parameter(Mandatory = $true)]
        [string]$DirectoryId
    )

    $discoverUri = "https://graph.microsoft.com/beta/servicePrincipals/{0}/synchronization/jobs/{1}/schema/directories/{2}/discover" -f $ProvisioningServicePrincipalId, $JobId, $DirectoryId
    return Invoke-MgGraphRequest -Method POST -Uri $discoverUri
}

Initialize-GraphModules

$scopes = @('Synchronization.ReadWrite.All', 'Application.Read.All')
Connect-MgGraph -TenantId $TenantId -Scopes $scopes -UseDeviceAuthentication -ContextScope Process -NoWelcome

try {
    $jobId = Resolve-SynchronizationJobId -ProvisioningServicePrincipalId $ServicePrincipalId -JobId $SynchronizationJobId
    Write-Host "Using synchronization job: $jobId"

    $schemaUri = "https://graph.microsoft.com/beta/servicePrincipals/$ServicePrincipalId/synchronization/jobs/$jobId/schema"
    Write-Host 'Fetching current schema...'
    $schema = Invoke-MgGraphRequest -Method GET -Uri $schemaUri

    # --- Identify the source (SCIM/external) directory from the synchronization rule ---
    $syncRule = $schema.synchronizationRules |
        Where-Object { $_.sourceDirectoryName -and $_.targetDirectoryName } |
        Select-Object -First 1

    if ($null -eq $syncRule) {
        throw 'Could not identify a synchronization rule with source and target directories.'
    }

    $sourceDir = $schema.directories | Where-Object { $_.name -eq $syncRule.sourceDirectoryName } | Select-Object -First 1
    if ($null -eq $sourceDir) {
        $availableDirectories = @($schema.directories | ForEach-Object { $_.name }) -join ', '
        throw "Could not find source directory '$($syncRule.sourceDirectoryName)' in schema. Available directories: $availableDirectories"
    }

    Write-Host "Source directory identified: $($sourceDir.name)"

    $userObjMapping = $syncRule.objectMappings | Where-Object { $_.sourceObjectName -and $_.targetObjectName } | Select-Object -First 1
    if ($null -eq $userObjMapping) {
        throw 'Could not find an object mapping in the synchronization rule.'
    }

    $sourceObjectName = $userObjMapping.sourceObjectName
    $userObjDef = Get-SourceObjectDefinition -Directory $sourceDir -ObjectName $sourceObjectName

    if ($null -eq $userObjDef -and -not [string]::IsNullOrWhiteSpace($sourceDir.id)) {
        Write-Host "Source directory does not currently expose object '$sourceObjectName'. Running directory discovery..."
        Invoke-DirectoryDiscover -ProvisioningServicePrincipalId $ServicePrincipalId -JobId $jobId -DirectoryId $sourceDir.id | Out-Null
        $schema = Invoke-MgGraphRequest -Method GET -Uri $schemaUri
        $sourceDir = $schema.directories | Where-Object { $_.name -eq $syncRule.sourceDirectoryName } | Select-Object -First 1
        $userObjDef = Get-SourceObjectDefinition -Directory $sourceDir -ObjectName $sourceObjectName
    }

    if ($null -eq $userObjDef) {
        $availableObjects = @($sourceDir.objects | ForEach-Object { $_.name }) -join ', '
        throw "Source directory '$($sourceDir.name)' does not contain a '$sourceObjectName' object definition. Available objects: $availableObjects"
    }

    $existingAttrNames = @($userObjDef.attributes | ForEach-Object { $_.name })

    $addedCount = 0
    foreach ($attr in $lifecycleSourceAttributes) {
        if ($existingAttrNames -contains $attr.SourceName) {
            Write-Host "Source attribute already exists, skipping: $($attr.SourceName)"
            continue
        }

        $newAttr = [ordered]@{
            name             = $attr.SourceName
            type             = 'String'
            multivalued      = $false
            required         = $false
            caseExact        = $false
            apiExpressions   = @()
            metadata         = @()
            referencedObjects = @()
        }

        $userObjDef.attributes += $newAttr
        Write-Host "Added source attribute: $($attr.SourceName)"
        $addedCount++
    }

    # --- Add missing attribute mappings to the synchronization rule ---
    $userObjMapping = $syncRule.objectMappings | Where-Object { $_.sourceObjectName -ieq $sourceObjectName } | Select-Object -First 1

    if ($null -eq $userObjMapping) {
        throw "Could not find User object mapping in synchronization rules."
    }

    $existingTargetNames = @($userObjMapping.attributeMappings | ForEach-Object { $_.targetAttributeName })

    foreach ($attr in $lifecycleSourceAttributes) {
        if ($existingTargetNames -contains $attr.TargetAttribute) {
            Write-Host "Attribute mapping already exists, skipping: $($attr.TargetAttribute)"
            continue
        }

        $newMapping = [ordered]@{
            targetAttributeName = $attr.TargetAttribute
            source              = [ordered]@{
                expression  = "[$($attr.SourceName)]"
                name        = $attr.SourceName
                type        = 'Attribute'
                parameters  = @()
            }
            flowBehavior        = 'FlowWhenChanged'
            flowType            = 'Always'
            matchingPriority    = 0
        }

        $userObjMapping.attributeMappings += $newMapping
        Write-Host "Added attribute mapping: $($attr.SourceName) -> $($attr.TargetAttribute)"
        $addedCount++
    }

    if ($addedCount -eq 0) {
        Write-Host 'Schema already up to date. No changes required.'
        return
    }

    # --- Save the updated schema ---
    $schemaJson = $schema | ConvertTo-Json -Depth 20
    if ($PSCmdlet.ShouldProcess($jobId, 'Update provisioning job schema')) {
        Invoke-MgGraphRequest -Method PUT -Uri $schemaUri -Body $schemaJson -ContentType 'application/json'
        Write-Host 'Schema updated successfully. employeeHireDate, employeeLeaveDateTime, and usageLocation are now available in the provisioning schema.'
        Write-Host "You can now view and verify the mappings in Entra ID > Enterprise Applications > [your app] > Provisioning > Mappings."
    }
}
finally {
    try {
        if ($null -ne (Get-MgContext)) {
            Disconnect-MgGraph | Out-Null
        }
    }
    catch { }
}
