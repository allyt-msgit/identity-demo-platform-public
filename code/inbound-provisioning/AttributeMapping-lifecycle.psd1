@{
    # CSV columns that contain date values - will be formatted as ISO 8601 UTC before SCIM upload
    DateFields = @('EmployeeHireDate', 'EmployeeLeaveDate')

    externalId  = 'EmployeeId'
    userName    = 'NewUserPrincipalName'
    displayName = 'FullName'
    title       = 'JobTitle'
    name        = @{
        givenName  = 'FirstName'
        familyName = 'LastName'
    }
    phoneNumbers = @(
        @{
            type  = 'mobile'
            value = 'MobilePhone'
        }
    )
    addresses = @(
        @{
            type   = 'work'
            region = 'Location'
        }
    )
    'urn:ietf:params:scim:schemas:extension:enterprise:2.0:User' = @{
        organization   = 'Company'
        department     = 'Department'
    }

    # Hub extension: lifecycle dates - wired into provisioning schema via Update-ProvisioningJobSchema.ps1
    'urn:ietf:params:scim:schemas:extension:hub:1.0:User' = @{
        employeeHireDate      = 'EmployeeHireDate'
        employeeLeaveDateTime = 'EmployeeLeaveDate'
        usageLocation         = 'UsageLocation'
    }
}