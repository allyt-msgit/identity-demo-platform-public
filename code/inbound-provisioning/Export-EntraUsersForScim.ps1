[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeGuests
)

$ErrorActionPreference = 'Stop'

if (-not $OutputPath) {
    $OutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'scim-lifecycle-template.csv'
}

function Initialize-GraphModules {
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

function Format-DateValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    try {
        return ([DateTime]$Value).ToString('yyyy-MM-dd')
    }
    catch {
        return [string]$Value
    }
}

Initialize-GraphModules

$scopes = @('User.Read.All', 'Organization.Read.All')
Connect-MgGraph -TenantId $TenantId -Scopes $scopes -UseDeviceAuthentication -ContextScope Process -NoWelcome

try {
    $properties = @(
        'id',
        'displayName',
        'givenName',
        'surname',
        'userPrincipalName',
        'department',
        'companyName',
        'officeLocation',
        'jobTitle',
        'mobilePhone',
        'employeeType',
        'employeeId',
        'employeeHireDate',
        'employeeLeaveDateTime',
        'usageLocation',
        'employeeOrgData',
        'userType'
    )

    $users = Get-MgUser -All -Property $properties
    if (-not $IncludeGuests) {
        $users = $users | Where-Object { $_.UserType -ne 'Guest' }
    }

    $rows = foreach ($user in $users) {
        [pscustomobject]@{
            NewUserPrincipalName = $user.UserPrincipalName
            FirstName            = $user.GivenName
            LastName             = $user.Surname
            FullName             = $user.DisplayName
            Department           = $user.Department
            CostCenter           = if ($null -ne $user.EmployeeOrgData) { $user.EmployeeOrgData.CostCenter } else { '' }
            Company              = $user.CompanyName
            Location             = $user.OfficeLocation
            JobTitle             = $user.JobTitle
            MobilePhone          = $user.MobilePhone
            EmployeeType         = $user.EmployeeType
            EmployeeId           = $user.EmployeeId
            EmployeeHireDate     = Format-DateValue -Value $user.EmployeeHireDate
            EmployeeLeaveDate    = Format-DateValue -Value $user.EmployeeLeaveDateTime
            UsageLocation        = $user.UsageLocation
            ManagerUserPrincipalName = ''
        }
    }

    $outputDirectory = Split-Path -Path $OutputPath -Parent
    if ($outputDirectory -and -not (Test-Path -Path $outputDirectory)) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
    }

    $rows | Sort-Object NewUserPrincipalName | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($rows.Count) users to $OutputPath"
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