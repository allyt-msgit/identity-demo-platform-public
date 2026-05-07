@{
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
    'urn:ietf:params:scim:schemas:extension:enterprise:2.0:User' = @{
        employeeNumber = 'EmployeeId'
        organization   = 'Company'
        department     = 'Department'
    }
}