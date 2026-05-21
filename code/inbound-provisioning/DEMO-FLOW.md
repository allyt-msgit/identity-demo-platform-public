# Demo Flow - End-to-End Joiner to Leaver

This guide is for live customer demos from your local Microsoft machine using this repository.

## Demo Environment

Run from:

- Repo root: `C:\Users\alturnbu\OneDrive - Microsoft\Github\identity-demo-platform`
- Working folder for commands: `C:\Users\alturnbu\OneDrive - Microsoft\Github\identity-demo-platform\code\inbound-provisioning`

Core demo scripts:

1. `Run-LifecycleProvisioningWorkflow.ps1` (main run)
2. `Invoke-HRInboundProvisioning.ps1` (called by the workflow)
3. `Update-ProvisioningJobSchema.ps1` (one-time setup already done)

## 1. Joiner Flow - Disco Brown

### 1.1 Add the user with GitHub Copilot Chat

Ask Copilot Chat to update `scim-lifecycle-template.csv` with a new joiner row.

Suggested prompt:

"Add a new row in `code/inbound-provisioning/scim-lifecycle-template.csv` for Disco Brown as a joiner. Set NewUserPrincipalName user04@example.com, FirstName Disco, LastName Brown, FullName Disco Brown, Department Security, CostCenter CC400, Company Proseware, Location London, JobTitle Security Analyst, MobilePhone +447700900004, EmployeeType Permanent, EmployeeId 88991, EmployeeHireDate 2026-05-04, EmployeeLeaveDate blank, UsageLocation GB, and ManagerUserPrincipalName manager@example.com. Keep all columns populated except EmployeeLeaveDate for a joiner."

Important:

- Include `Location` and `UsageLocation` every time so licensing and location-based policy logic can execute correctly.
- Treat `NewUserPrincipalName` as the primary mail/sign-in attribute for this lifecycle template.
- This template does not include a separate `MailNickname` column. If you need mail alias attributes in the demo, use the v1 template flow or extend the lifecycle schema first.

### 1.2 Joiner row example

Use this as a baseline (adjust department/title as needed for the story):

```csv
NewUserPrincipalName,FirstName,LastName,FullName,Department,CostCenter,Company,Location,JobTitle,MobilePhone,EmployeeType,EmployeeId,EmployeeHireDate,EmployeeLeaveDate,UsageLocation,ManagerUserPrincipalName
user04@example.com,Disco,Brown,Disco Brown,Security,CC400,Proseware,London,Security Analyst,+447700900004,Permanent,88991,2026-05-04,,GB,manager@example.com
```

### 1.3 Run the lifecycle workflow

```powershell
Set-Location "C:\Users\alturnbu\OneDrive - Microsoft\Github\identity-demo-platform\code\inbound-provisioning"
.\Run-LifecycleProvisioningWorkflow.ps1 -TenantId "<tenant-guid>" -ServicePrincipalId "<provisioning-app-object-id>"
```

What this run does:

- Creates/updates Disco via inbound provisioning API
- Flows lifecycle fields (hire date, usage location)
- Applies manager assignment (CSV value or default manager)

## 2. Show Evidence in Entra Logs

### 2.1 Provisioning logs (API provisioning details)

In Entra admin center:

1. Go to Enterprise applications
2. Open the API-driven inbound provisioning app
3. Go to Provisioning -> View provisioning logs
4. Filter by user `user04@example.com`

What to show:

- Import/match/provision steps
- Modified properties (for example hire date/usage location)
- Success status and timestamps

### 2.2 Audit logs (manager and directory updates)

In Entra admin center:

1. Go to Monitoring & health -> Audit logs
2. Filter Target to Disco Brown or UPN
3. Filter activities like user updates / manager reference updates

What to show:

- Manager assignment event
- Any additional user property updates recorded as directory audit events

## 3. Run Entra Lifecycle Workflow

After proving identity provisioning and logs, run the lifecycle workflow in Entra.

What to narrate:

- Trigger condition reached from joiner data
- Workflow actions executed
- Handoff to manager communications

## 4. Manager Email Proof in Edge Profile

Pivot to manager profile in Edge (`manager-user`) and show the lifecycle/welcome email landing for manager review.

## 5. New User Sign-in and Access Package

1. Sign in as new user `user04@example.com`
2. Show account access posture
3. Request access package `global-security-teams`

## 6. GSA Proof on Windows 365 VM

Pivot to `cturnbull` Windows 365 VM and demonstrate GSA client access to:

- HTTPS resource
- SMB share

## 7. Leaver Flow - Mint Slice

Update Mint for leaver scenario in `scim-lifecycle-template.csv`:

- Keep manager as required for your story
- Clear `EmployeeHireDate`
- Set `EmployeeLeaveDate` to today's date

For this demo date, use:

- `EmployeeLeaveDate = 2026-05-06`

Then run the same workflow again:

```powershell
Set-Location "C:\Users\alturnbu\OneDrive - Microsoft\Github\identity-demo-platform\code\inbound-provisioning"
.\Run-LifecycleProvisioningWorkflow.ps1 -TenantId "<tenant-guid>" -ServicePrincipalId "<provisioning-app-object-id>"
```

Finally, show:

- Provisioning logs for Mint leave-date update
- Audit logs for downstream identity change evidence
- Lifecycle workflow execution outcome for leaver actions

## 8. Live Demo Talk Track Summary

1. Add joiner in CSV using Copilot Chat
2. Run lifecycle workflow from local machine
3. Show provisioning logs (API detail)
4. Show audit logs (directory-level proof)
5. Run Entra lifecycle workflow
6. Show manager email in Edge (`manager-user`)
7. Sign in as new user and request `global-security-teams`
8. Show GSA access on `cturnbull` Windows 365 VM
9. Switch user to leaver and rerun the same automation

## 9. Next Time Improvements

1. Add GSA client deployment to Intune build baseline so endpoint setup is consistent before the demo.
2. Extend lifecycle schema to include extra profile attributes for richer demos, for example:
	- MailNickname
	- StreetAddress
	- City
	- Country
	- OfficeLocation
3. Update mapping files and provisioning schema to flow those additional attributes.
4. Add a pre-demo validation step that checks required joiner fields are present before running sync.
5. Enable passwordless authentication in tenant baseline for demo identities.
6. Set up Microsoft Entra Verified ID scenarios for demo storyline.
