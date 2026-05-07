# Inbound Provisioning Starter

This folder contains a basic starter for API-driven inbound provisioning into Microsoft Entra.

It is designed for your demo environment and uses the existing CSV shape from `code/hr-user-updates-template.csv` as the source format.

## What This Starter Does

- Reads your HR CSV file
- Maps the CSV columns into a SCIM bulk request payload
- Writes the payload to JSON for inspection
- Optionally uploads the payload to the Entra inbound provisioning `bulkUpload` endpoint

## Demo Execution From Local Machine

For customer demos, this solution is run locally from your Microsoft-managed machine and repository clone:

- Repo root: `C:\Users\alturnbu\OneDrive - Microsoft\Github\identity-demo-platform`
- Inbound provisioning folder: `C:\Users\alturnbu\OneDrive - Microsoft\Github\identity-demo-platform\code\inbound-provisioning`

High-level script flow for the lifecycle demo:

1. Optional one-time schema prep:
	- `Update-ProvisioningJobSchema.ps1`
2. Main demo run:
	- `Run-LifecycleProvisioningWorkflow.ps1`
3. Workflow internals:
	- `Run-LifecycleProvisioningWorkflow.ps1` calls `Invoke-HRInboundProvisioning.ps1`
	- `Invoke-HRInboundProvisioning.ps1` builds SCIM payload and calls Graph `bulkUpload`
	- `Run-LifecycleProvisioningWorkflow.ps1` then applies manager assignments (CSV manager value or default manager)

For the full customer-facing step-by-step demo narrative (joiner, logs, lifecycle workflow, manager email proof, access package, GSA access, and leaver), see:

- `DEMO-FLOW.md`

## Files

- `AttributeMapping.psd1`: maps your CSV columns to SCIM fields
- `AttributeMapping-lifecycle.psd1`: expanded mapping for lifecycle fields (location, employee type, hire and leave dates, usage location)
- `Invoke-HRInboundProvisioning.ps1`: generates and optionally uploads the SCIM bulk payload
- `scim-v1-template.csv`: dedicated v1 CSV template for the SCIM path
- `scim-lifecycle-template.csv`: expanded CSV template for lifecycle workflows
- `Export-EntraUsersForScim.ps1`: exports Entra users into the lifecycle CSV shape
- `Run-LifecycleProvisioningWorkflow.ps1`: single-stage lifecycle workflow using the inbound provisioning API
- `Update-ProvisioningJobSchema.ps1`: one-time schema updater for custom lifecycle source attributes

## v1 Field Mapping

This v1 mapping is intentionally narrowed to the minimum agreed demo fields:

- `NewUserPrincipalName`
- `FirstName`
- `LastName`
- `FullName`
- `Department`
- `Company`
- `JobTitle`
- `MobilePhone`
- `EmployeeId`

All other CSV columns are currently ignored by the mapping file.

This template is intentionally separate from `code/hr-user-updates-template.csv` so your legacy Graph update flow remains independent.

### Standard SCIM Core

| CSV column | SCIM field |
|---|---|
| `EmployeeId` | `externalId` |
| `NewUserPrincipalName` | `userName` |
| `FullName` | `displayName` |
| `JobTitle` | `title` |
| `FirstName` | `name.givenName` |
| `LastName` | `name.familyName` |
| `MobilePhone` | `phoneNumbers[type=mobile].value` |

### Standard SCIM Enterprise Extension

| CSV column | SCIM field |
|---|---|
| `EmployeeId` | `enterprise.employeeNumber` |
| `Company` | `enterprise.organization` |
| `Department` | `enterprise.department` |

## Assumptions In This Basic Version

- The script always sets `active = true` for v1 unless you customize that logic.

## Entra Setup Checklist

### 1. Create the inbound provisioning app

In the Entra admin center:

1. Create and configure an API-driven inbound provisioning app.
2. Open the provisioning app properties.
3. Record the provisioning app Object ID. This is the `ServicePrincipalId` used by the script.

### 2. Create authentication app registration

1. Create or reuse an app registration for the upload process.
2. Add a client certificate.
3. Record the app registration Client ID.

For early testing, you can use interactive device authentication instead of certificate auth.

### 3. Grant the app or signed-in admin the required access

For basic testing with interactive auth, the script uses these Graph scopes:

- `SynchronizationData-User.Upload`
- `Application.Read.All`
- `Synchronization.Read.All`

If you use certificate auth, you will need the equivalent application permissions and admin consent in the tenant.

### 4. Keep schema simple for v1

For this v1 cut, use only SCIM core and SCIM enterprise extension mappings.

### 5. Configure attribute mappings

Map incoming SCIM fields to target Entra attributes.

Good first-pass mappings:

- `userName` -> user principal name or matching sign-in attribute
- `name.givenName` -> given name
- `name.familyName` -> surname
- `displayName` -> display name
- `title` -> job title
- `enterprise.department` -> department
- `enterprise.organization` -> company name
- `enterprise.costCenter` -> cost center if supported in your target mapping set
- `phoneNumbers[type eq "mobile"].value` -> mobile phone

Then add custom extension fields after the basic flow works.

## Lifecycle Field Expansion

If your workflows depend on lifecycle fields, use the expanded files:

- CSV: `scim-lifecycle-template.csv`
- Mapping: `AttributeMapping-lifecycle.psd1`

You can keep a single CSV for the full lifecycle flow. The inbound provisioning API now carries the lifecycle attributes directly so they show in the same provisioning logs as the create and update events.

Expanded fields in this mode:

- `CostCenter`
- `Location`
- `EmployeeType`
- `EmployeeId`
- `EmployeeHireDate`
- `EmployeeLeaveDate`
- `UsageLocation`
- `ManagerUserPrincipalName`

SCIM additions in lifecycle mode:

- Enterprise extension (`urn:ietf:params:scim:schemas:extension:enterprise:2.0:User`)
	- `organization`
	- `department`

- Hub extension (`urn:ietf:params:scim:schemas:extension:hub:1.0:User`)
	- `employeeHireDate`
	- `employeeLeaveDateTime`
	- `usageLocation`

Before first use, run the schema updater once so those Hub extension attributes are available in the provisioning job schema and mappings:

```powershell
.\Update-ProvisioningJobSchema.ps1 -TenantId "<tenant-id>" -ServicePrincipalId "<provisioning-app-object-id>"
```

## Export Existing Entra Users To CSV

Generate a full editable baseline CSV from current Entra users:

```powershell
.\Export-EntraUsersForScim.ps1 -TenantId "<tenant-id>"
```

This writes `scim-lifecycle-template.csv` sorted by UPN. By default, guest users are excluded.

To include guests:

```powershell
.\Export-EntraUsersForScim.ps1 -TenantId "<tenant-id>" -IncludeGuests
```

## Lifecycle Workflow

This mode keeps lifecycle values in the inbound provisioning path so user creation, updates, and lifecycle attribute changes appear in the same Entra provisioning logs.

After the SCIM upload completes, the workflow also applies manager assignments using Microsoft Graph:

- Uses `ManagerUserPrincipalName` from the CSV when populated
- Uses default manager `manager@example.com` when blank
- Skips self-manager assignment

Run the lifecycle workflow:

```powershell
.\Run-LifecycleProvisioningWorkflow.ps1 -TenantId "<tenant-id>" -ServicePrincipalId "<provisioning-app-object-id>"
```

Override the default manager for a specific run:

```powershell
.\Run-LifecycleProvisioningWorkflow.ps1 -TenantId "<tenant-id>" -ServicePrincipalId "<provisioning-app-object-id>" -DefaultManagerUserPrincipalName "<manager-upn>"
```

## Commands

Generate payload only:

```powershell
.\Invoke-HRInboundProvisioning.ps1 -CsvPath .\scim-v1-template.csv -GenerateOnly
```

Generate payload and upload using interactive auth:

```powershell
.\Invoke-HRInboundProvisioning.ps1 -CsvPath .\scim-v1-template.csv -TenantId "<tenant-id>" -ServicePrincipalId "<provisioning-app-object-id>"
```

Generate payload and upload with lifecycle mapping:

```powershell
.\Invoke-HRInboundProvisioning.ps1 -CsvPath .\scim-lifecycle-template.csv -AttributeMappingPath .\AttributeMapping-lifecycle.psd1 -TenantId "<tenant-id>" -ServicePrincipalId "<provisioning-app-object-id>"
```

### Entra Mapping Additions For Lifecycle Mode

Source (SCIM/API) -> Target (Entra)

- `externalId` -> `employeeId` (if target is exposed)
- `urn:ietf:params:scim:schemas:extension:enterprise:2.0:User:organization` -> `companyName`
- `urn:ietf:params:scim:schemas:extension:enterprise:2.0:User:department` -> `department`
- `urn:ietf:params:scim:schemas:extension:hub:1.0:User:employeeHireDate` -> `employeeHireDate`
- `urn:ietf:params:scim:schemas:extension:hub:1.0:User:employeeLeaveDateTime` -> `employeeLeaveDateTime`
- `urn:ietf:params:scim:schemas:extension:hub:1.0:User:usageLocation` -> `usageLocation`

If these source attributes do not appear initially, rerun `Update-ProvisioningJobSchema.ps1` and refresh the provisioning mappings UI.

Generate payload and upload using certificate auth:

```powershell
.\Invoke-HRInboundProvisioning.ps1 -CsvPath .\scim-v1-template.csv -TenantId "<tenant-id>" -ServicePrincipalId "<provisioning-app-object-id>" -ClientId "<app-client-id>" -ClientCertificateThumbprint "<thumbprint>"
```

## Suggested Build Sequence

1. Run generate-only mode and inspect the JSON.
2. Configure the Entra provisioning app.
3. Upload a CSV containing one user.
4. Review provisioning logs.
5. Fix mappings before increasing the number of fields or records.

## Success Evidence Example

Use Provisioning log details to prove a real attribute change was applied.

Example from a successful update:

- Property: `jobTitle`
- Old value: `Consultant`
- New value: `SOC Analyst`

For demo documentation, capture these sections from the log entry:

1. Steps tab showing import, match, and provision stages.
2. Modified Properties tab showing old and new values.
3. Summary tab with action outcome.

## Known Limits In This Starter

- It does not yet fetch provisioning logs for you.
- It assumes the first synchronization job under the provisioning app is the correct one if you do not supply `SynchronizationJobId`.
- Manager assignment is performed by Graph after upload and appears in Entra audit logs, not provisioning logs.
- Cost center and custom security attributes are still outside the inbound SCIM path in this starter.