[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ServicePrincipalId,

    [Parameter(Mandatory = $false)]
    [string]$CsvPath = (Join-Path -Path $PSScriptRoot -ChildPath 'scim-lifecycle-template.csv'),

    [Parameter(Mandatory = $false)]
    [string]$AttributeMappingPath = (Join-Path -Path $PSScriptRoot -ChildPath 'AttributeMapping-lifecycle.psd1'),

    [Parameter(Mandatory = $false)]
    [string]$DefaultManagerUserPrincipalName = 'manager@example.com'
)

$ErrorActionPreference = 'Stop'

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

function Initialize-ManagerModules {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
        Write-Host 'Installing Microsoft.Graph.Users for current user...'
        Install-Module Microsoft.Graph.Users -Scope CurrentUser -Force -AllowClobber
    }

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Host 'Installing Microsoft.Graph.Authentication for current user...'
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
    }

    Import-Module Microsoft.Graph.Users
    Import-Module Microsoft.Graph.Authentication
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

function Set-ManagersFromCsv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CsvFilePath,

        [Parameter(Mandatory = $true)]
        [string]$Tenant,

        [Parameter(Mandatory = $true)]
        [string]$DefaultManagerUpn
    )

    $rows = Import-Csv -Path $CsvFilePath
    if (-not $rows -or $rows.Count -eq 0) {
        Write-Host 'No rows found for manager assignment.'
        return
    }

    Initialize-ManagerModules

    $scopes = @('User.ReadWrite.All', 'Directory.ReadWrite.All')
    Connect-MgGraph -TenantId $Tenant -Scopes $scopes -UseDeviceAuthentication -ContextScope Process -NoWelcome

    try {
        $defaultManager = Get-MgUser -UserId $DefaultManagerUpn -Property 'id,userPrincipalName' -ErrorAction Stop

        foreach ($row in $rows) {
            $userUpn = Get-TrimmedValue -Value $row.NewUserPrincipalName
            if ($null -eq $userUpn) {
                Write-Warning 'Skipping row with no NewUserPrincipalName.'
                continue
            }

            $rowManagerUpn = Get-TrimmedValue -Value $row.ManagerUserPrincipalName
            $managerUpn = if ($null -ne $rowManagerUpn) { $rowManagerUpn } else { $DefaultManagerUpn }

            if ($userUpn -ieq $managerUpn) {
                Write-Warning "Skipping self-manager assignment for $userUpn"
                continue
            }

            try {
                $user = Get-MgUser -UserId $userUpn -Property 'id,userPrincipalName' -ErrorAction Stop

                $managerId = $defaultManager.Id
                if ($managerUpn -ine $DefaultManagerUpn) {
                    $manager = Get-MgUser -UserId $managerUpn -Property 'id,userPrincipalName' -ErrorAction Stop
                    $managerId = $manager.Id
                }

                $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$managerId" } | ConvertTo-Json
                Invoke-MgGraphRequest -Method PUT -Uri ("https://graph.microsoft.com/v1.0/users/{0}/manager/`$ref" -f $user.Id) -Body $body -ContentType 'application/json' | Out-Null
                Write-Host "Manager set: $userUpn -> $managerUpn"
            }
            catch {
                Write-Warning "Failed to set manager for $userUpn. $($_.Exception.Message)"
            }
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
}

$resolvedCsvPath = Resolve-PathStrict -Path $CsvPath
$resolvedAttributeMappingPath = Resolve-PathStrict -Path $AttributeMappingPath

$inboundScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-HRInboundProvisioning.ps1'
$inboundScriptPath = Resolve-PathStrict -Path $inboundScriptPath

Write-Host 'Running inbound SCIM provisioning upload...'
& $inboundScriptPath `
    -CsvPath $resolvedCsvPath `
    -AttributeMappingPath $resolvedAttributeMappingPath `
    -TenantId $TenantId `
    -ServicePrincipalId $ServicePrincipalId

Write-Host 'Applying manager assignments...'
Set-ManagersFromCsv -CsvFilePath $resolvedCsvPath -Tenant $TenantId -DefaultManagerUpn $DefaultManagerUserPrincipalName

Write-Host 'Workflow complete.'