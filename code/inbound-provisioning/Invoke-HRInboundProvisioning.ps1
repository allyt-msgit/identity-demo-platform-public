[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [string]$AttributeMappingPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$CustomScimNamespace = 'urn:ietf:params:scim:schemas:extension:hub:1.0:User',

    [Parameter(Mandatory = $false)]
    [int]$BatchSize = 50,

    [Parameter(Mandatory = $false)]
    [switch]$GenerateOnly,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$ServicePrincipalId,

    [Parameter(Mandatory = $false)]
    [string]$SynchronizationJobId,

    [Parameter(Mandatory = $false)]
    [string]$ClientId,

    [Parameter(Mandatory = $false)]
    [string]$ClientCertificateThumbprint
)

$ErrorActionPreference = 'Stop'
$coreSchema = 'urn:ietf:params:scim:schemas:core:2.0:User'
$enterpriseSchema = 'urn:ietf:params:scim:schemas:extension:enterprise:2.0:User'

if (-not $AttributeMappingPath) {
    $AttributeMappingPath = Join-Path -Path $PSScriptRoot -ChildPath 'AttributeMapping.psd1'
}

if (-not $OutputPath) {
    $OutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'BulkRequestPayload.json'
}

function Resolve-PathStrict {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Path not found: $Path"
    }

    return (Resolve-Path -Path $Path).Path
}

function Get-TrimmedValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    $trimmed = $text.Trim()
    if ($trimmed.Length -eq 0) {
        return $null
    }

    return $trimmed
}

function Test-RowHasProperty {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Row,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    return $null -ne ($Row.PSObject.Properties[$PropertyName])
}

function Resolve-MappingValue {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Row,

        [Parameter(Mandatory = $true)]
        [object]$MappingValue
    )

    if ($MappingValue -is [string]) {
        if (Test-RowHasProperty -Row $Row -PropertyName $MappingValue) {
            return Get-TrimmedValue -Value $Row.$MappingValue
        }

        return $MappingValue
    }

    if ($MappingValue -is [System.Collections.IDictionary]) {
        $resolved = @{}
        foreach ($entry in $MappingValue.GetEnumerator()) {
            $childValue = Resolve-MappingValue -Row $Row -MappingValue $entry.Value
            if ($null -ne $childValue) {
                $resolved[$entry.Key] = $childValue
            }
        }

        if ($resolved.Count -eq 0) {
            return $null
        }

        return $resolved
    }

    if (($MappingValue -is [System.Collections.IEnumerable]) -and -not ($MappingValue -is [string]) -and -not ($MappingValue -is [System.Collections.IDictionary])) {
        $resolvedItems = @()
        foreach ($item in $MappingValue) {
            $resolvedItem = Resolve-MappingValue -Row $Row -MappingValue $item
            if ($null -ne $resolvedItem) {
                $resolvedItems += ,$resolvedItem
            }
        }

        if ($resolvedItems.Count -eq 0) {
            return $null
        }

        return ,$resolvedItems
    }

    return $MappingValue
}

function Get-ActiveState {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Row
    )

    return $true
}

function New-ScimUserData {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Row,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$AttributeMapping,

        [Parameter(Mandatory = $true)]
        [string]$CustomNamespace
    )

    $coreData = @{}
    $enterpriseData = $null
    $customData = $null

    foreach ($entry in $AttributeMapping.GetEnumerator()) {
        $resolvedValue = Resolve-MappingValue -Row $Row -MappingValue $entry.Value
        if ($null -eq $resolvedValue) {
            continue
        }

        if ($entry.Key -eq $enterpriseSchema) {
            $enterpriseData = $resolvedValue
            continue
        }

        if ($entry.Key -eq $CustomNamespace) {
            $customData = $resolvedValue
            continue
        }

        $coreData[$entry.Key] = $resolvedValue
    }

    $coreData['active'] = Get-ActiveState -Row $Row

    $schemas = New-Object System.Collections.Generic.List[string]
    $schemas.Add($coreSchema)

    if ($null -ne $enterpriseData -and $enterpriseData.Count -gt 0) {
        $schemas.Add($enterpriseSchema)
    }

    if ($null -ne $customData -and $customData.Count -gt 0) {
        $schemas.Add($CustomNamespace)
    }

    $userData = @{
        schemas = @($schemas)
    }

    foreach ($entry in $coreData.GetEnumerator()) {
        $userData[$entry.Key] = $entry.Value
    }

    if ($null -ne $enterpriseData -and $enterpriseData.Count -gt 0) {
        $userData[$enterpriseSchema] = $enterpriseData
    }

    if ($null -ne $customData -and $customData.Count -gt 0) {
        $userData[$CustomNamespace] = $customData
    }

    return $userData
}

function New-BulkOperation {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$UserData
    )

    return @{
        method = 'POST'
        bulkId = [guid]::NewGuid().Guid
        path   = '/Users'
        data   = $UserData
    }
}

function Split-Operations {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Operations,

        [Parameter(Mandatory = $true)]
        [int]$Size
    )

    if ($Size -lt 1) {
        throw 'BatchSize must be at least 1.'
    }

    $batches = New-Object System.Collections.ArrayList
    for ($index = 0; $index -lt $Operations.Count; $index += $Size) {
        $endIndex = [Math]::Min($index + $Size - 1, $Operations.Count - 1)
        [void]$batches.Add([object[]]@($Operations[$index..$endIndex]))
    }

    return ,($batches.ToArray())
}

function New-BulkPayload {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Operations
    )

    return @{
        schemas      = @('urn:ietf:params:scim:api:messages:2.0:BulkRequest')
        Operations   = $Operations
        failOnErrors = $null
    }
}

function Initialize-GraphModules {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Host 'Installing Microsoft.Graph.Authentication for current user...'
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
    }

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
        Write-Host 'Installing Microsoft.Graph.Applications for current user...'
        Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force -AllowClobber
    }

    Import-Module Microsoft.Graph.Authentication
    Import-Module Microsoft.Graph.Applications
}

function Connect-GraphForProvisioning {
    $scopes = @(
        'SynchronizationData-User.Upload',
        'Application.Read.All',
        'Synchronization.Read.All'
    )

    if ($ClientId -and $ClientCertificateThumbprint) {
        Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $ClientCertificateThumbprint -NoWelcome
        return
    }

    Connect-MgGraph -TenantId $TenantId -Scopes $scopes -UseDeviceAuthentication -ContextScope Process -NoWelcome
}

function Resolve-SynchronizationJob {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProvisioningServicePrincipalId,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$JobId
    )

    if ($JobId) {
        return $JobId
    }

    $response = Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/beta/servicePrincipals/{0}/synchronization/jobs" -f $ProvisioningServicePrincipalId)
    if ($null -eq $response.value -or $response.value.Count -eq 0) {
        throw 'No synchronization jobs were found for the provisioning app. Complete the Entra provisioning app setup first.'
    }

    return $response.value[0].id
}

function Invoke-BulkUpload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProvisioningServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$JobId,

        [Parameter(Mandatory = $true)]
        [string]$PayloadJson
    )

    $uri = "https://graph.microsoft.com/beta/servicePrincipals/{0}/synchronization/jobs/{1}/bulkUpload" -f $ProvisioningServicePrincipalId, $JobId
    return Invoke-MgGraphRequest -Method POST -Uri $uri -Body $PayloadJson -ContentType 'application/scim+json'
}

$resolvedCsvPath = Resolve-PathStrict -Path $CsvPath
$resolvedMappingPath = Resolve-PathStrict -Path $AttributeMappingPath
$attributeMapping = Import-PowerShellDataFile -Path $resolvedMappingPath

# Extract optional DateFields list and remove it from the mapping before attribute processing
$dateFields = @()
if ($attributeMapping.ContainsKey('DateFields')) {
    $dateFields = [string[]]$attributeMapping['DateFields']
    $cleanMapping = @{}
    foreach ($key in $attributeMapping.Keys) {
        if ($key -ne 'DateFields') {
            $cleanMapping[$key] = $attributeMapping[$key]
        }
    }
    $attributeMapping = $cleanMapping
}

$rows = Import-Csv -Path $resolvedCsvPath

if (-not $rows -or $rows.Count -eq 0) {
    throw "CSV file contains no data rows: $resolvedCsvPath"
}

$operations = @()
foreach ($row in $rows) {
    # Pre-format date fields as ISO 8601 UTC so Entra accepts them as datetime values
    foreach ($dateField in $dateFields) {
        if ($null -ne $row.PSObject.Properties[$dateField]) {
            $dateValue = $row.$dateField
            if (-not [string]::IsNullOrWhiteSpace($dateValue)) {
                try {
                    $parsedDate = [datetime]::Parse($dateValue)
                    $row.$dateField = $parsedDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                }
                catch {
                    Write-Warning "Could not parse date value '$dateValue' in column '$dateField' for row. Leaving as-is."
                }
            }
        }
    }

    $userData = New-ScimUserData -Row $row -AttributeMapping $attributeMapping -CustomNamespace $CustomScimNamespace
    $operations += ,(New-BulkOperation -UserData $userData)
}

$batches = Split-Operations -Operations $operations -Size $BatchSize
$outputDirectory = Split-Path -Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -Path $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

for ($batchIndex = 0; $batchIndex -lt $batches.Count; $batchIndex++) {
    $payload = New-BulkPayload -Operations $batches[$batchIndex]
    $json = $payload | ConvertTo-Json -Depth 10

    $batchOutputPath = $OutputPath
    if ($batches.Count -gt 1) {
        $batchFileName = ('{0}-{1}.json' -f [System.IO.Path]::GetFileNameWithoutExtension($OutputPath), ($batchIndex + 1))
        $batchOutputPath = [System.IO.Path]::Combine(
            (Split-Path -Path $OutputPath -Parent),
            $batchFileName
        )
    }

    Set-Content -Path $batchOutputPath -Value $json -Encoding UTF8
    Write-Host "Generated payload: $batchOutputPath"
}

if ($GenerateOnly -or -not $ServicePrincipalId -or -not $TenantId) {
    Write-Host 'Generate-only mode complete. Provide TenantId and ServicePrincipalId to upload the payload.'
    return
}

Initialize-GraphModules
Connect-GraphForProvisioning

try {
    $jobId = Resolve-SynchronizationJob -ProvisioningServicePrincipalId $ServicePrincipalId -JobId $SynchronizationJobId
    Write-Host "Using synchronization job: $jobId"

    foreach ($batchIndex in 0..($batches.Count - 1)) {
        $batchPath = $OutputPath
        if ($batches.Count -gt 1) {
            $batchFileName = ('{0}-{1}.json' -f [System.IO.Path]::GetFileNameWithoutExtension($OutputPath), ($batchIndex + 1))
            $batchPath = [System.IO.Path]::Combine(
                (Split-Path -Path $OutputPath -Parent),
                $batchFileName
            )
        }

        $payloadJson = Get-Content -Path $batchPath -Raw
        Invoke-BulkUpload -ProvisioningServicePrincipalId $ServicePrincipalId -JobId $jobId -PayloadJson $payloadJson | Out-Null
        Write-Host "Uploaded batch $($batchIndex + 1) of $($batches.Count)"
    }
}
finally {
    try {
        if ($null -ne (Get-MgContext)) {
            Disconnect-MgGraph | Out-Null
        }
    }
    catch {
    }
}