# Go-Live Guide: CSV-Based Inbound Provisioning in Production

This guide outlines the technical approach and considerations for deploying the API-driven inbound provisioning pipeline from a local development laptop to a production environment using CSV file-based integration.

## Important Note: Direct SCIM Connectors

**If your HR system has a direct SCIM connector available (Workday, SAP SuccessFactors, ADP, etc.), you should use that instead.** Direct SCIM connectors provide:
- Real-time or near-real-time provisioning (vs. scheduled CSV imports)
- Built-in attribute mapping and transformation
- Automatic error handling and retry logic
- Better performance and reliability

This guide is specifically for scenarios where **CSV file export is the primary integration method**—such as custom HR systems, legacy systems without APIs, or organizations that prefer batch processing over real-time sync.

For HR-driven provisioning with direct connectors, see: [Microsoft Entra HR-driven provisioning](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/what-is-hr-driven-provisioning)

## Overview

The current demo runs locally on a laptop, executing PowerShell scripts that:
1. Read HR CSV files
2. Transform data into SCIM bulk upload payloads
3. Post to Microsoft Entra's inbound provisioning API
4. Assign managers and enforce lifecycle policies

In production, this workflow must be:
- **Triggered systematically** (scheduled, event-driven, or on-demand)
- **Secured** (credentials, audit trails, error handling)
- **Observable** (logging, alerting, compliance)
- **Resilient** (retry logic, dead-letter queues, data validation)
- **Compliant** (change control, approvals, access governance)

## Production Deployment Patterns

### Option 1: Scheduled Automation via Azure Automation Account (Recommended for Simplicity)

**Architecture:**
- HR system (SAP, Workday, ADP) exports employee delta to Azure Blob Storage on schedule
- Azure Automation Account hosts the PowerShell runbook in a managed environment
- Automation Account runs on schedule or triggered by Event Grid
- Runbook executes the `Run-LifecycleProvisioningWorkflow.ps1` logic
- Results logged to Azure Log Analytics and audit storage

**Setup Steps:**
1. Create Azure Automation Account in production subscription
   - Select region near where your Entra tenant runs
   - Enable system-assigned managed identity
   
2. Create a System-Assigned Managed Identity for the Automation Account
   - Grant Microsoft Entra roles:
     - `Synchronization.ReadWrite.All` (to manage provisioning jobs)
     - `Application.Read.All` (to read provisioning job templates)
     - `User.ReadWrite.All` (to create/update users)
   - Grant Azure RBAC roles:
     - `Storage Blob Data Reader` on Azure Storage Account (if pulling CSV from Blob)

3. Upload the provisioning scripts:
   - `Run-LifecycleProvisioningWorkflow.ps1` → Automation Account Runbooks
   - `AttributeMapping-lifecycle.psd1` → Automation Account Modules
   - Include retry logic and error handling in runbook

4. Configure the runbook:
   ```powershell
   Param(
       [Parameter(Mandatory=$true)]
       [string]$TenantId,
       
       [Parameter(Mandatory=$true)]
       [string]$BlobContainerUri,
       
       [Parameter(Mandatory=$false)]
       [switch]$WhatIf
   )
   
   # Use managed identity to connect
   Connect-MgGraph -Identity -TenantId $TenantId
   
   # Download CSV from Blob Storage
   $csvFile = Get-AzStorageBlobContent -Blob "hr-export.csv" -Container "provisioning" -Force
   
   # Run provisioning workflow (same logic as laptop version)
   & ".\Run-LifecycleProvisioningWorkflow.ps1" -CsvPath $csvFile.Name -WhatIf:$WhatIf
   ```

5. Create a schedule:
   - Frequency: Daily at 2 AM (or off-peak time)
   - Time zone: UTC (recommended for consistency)
   - Alternative: Trigger via Event Grid when HR export lands in Blob Storage

6. Configure monitoring and alerts:
   - Enable Azure Monitor alerts for runbook failures
   - Log all output to Log Analytics workspace
   - Email alert if: runbook fails, >5% records error, deprovisioning occurs
   - Archive runbook logs to compliance storage (immutable)

**Advantages:**
- No additional infrastructure to manage
- Built-in Azure Monitor/Log Analytics integration
- Managed identity eliminates credential rotation burden
- Cost-effective (~$3-5/month for daily runs)
- Works with Blob Storage, SharePoint, or any file source

**Considerations:**
- Scripts must be adapted to read from Blob/cloud storage, not local filesystem
- HR CSV export must be uploaded to Blob Storage before runbook executes
- Need proper error handling and notifications (built-in to runbook)
- Requires PowerShell 7+ runtime in Automation Account

**Estimated timeline:** 1-2 weeks to set up and test

---

### Option 2: Logic App with Managed Connectors (Approval-Friendly)

**Architecture:**
- Logic App triggered on schedule or HTTP webhook
- Managed connectors read HR export from SharePoint Online or OneDrive
- Logic App calls Azure Function to execute provisioning logic
- Sends completion summary via Teams or email
- Optional: Human approval gate before running provisioning

**Setup Steps:**
1. Create Logic App in production subscription
   
2. Configure trigger:
   - Option A (Schedule): Recurrence trigger at daily 2 AM
   - Option B (Event): When file created in SharePoint folder
   - Option C (Manual): HTTP POST endpoint for on-demand runs

3. Add actions:
   ```
   Step 1: SharePoint - Get file content (HR export)
   Step 2: Data Operations - Parse CSV
   Step 3: Approval - Require manager sign-off [OPTIONAL]
   Step 4: Azure Function - Call function to run provisioning
   Step 5: Teams - Send notification with results
   ```

4. Create Azure Function to wrap provisioning logic:
   - Runtime: PowerShell 7
   - Inputs: CSV content from Logic App
   - Output: Success/failure status, count of created/updated/failed users
   - Returns: JSON with provisioning summary

5. Error handling:
   - If approval times out after 24 hours, send escalation email
   - If function fails, retry up to 3 times
   - On final failure, create incident in ServiceNow/Azure DevOps

**Advantages:**
- Visual workflow designer (no code required for orchestration)
- Approval gates for compliance/change control
- Native integration with Microsoft 365 (SharePoint, Teams, Outlook)
- Easy to add additional steps (notifications, data validation, etc.)
- Can be triggered manually for emergency provisioning

**Considerations:**
- Requires Azure Function to host PowerShell logic
- Managed connectors have throttling limits (400 calls/day for SharePoint)
- Logic App costs ~$0.20 per trigger (can be expensive at scale)
- Function costs depend on execution duration

**Estimated cost:** $30-50/month for daily runs
**Estimated timeline:** 2-3 weeks to set up and test

---

### Option 3: CI/CD Pipeline with Azure DevOps (Enterprise-Ready)

**Architecture:**
- PowerShell scripts and HR export CSV stored in Git repository
- Azure DevOps Pipeline orchestrates multi-stage deployment
- Stage 1: Validate (schema check, connectivity test)
- Stage 2: Approve (manager/compliance sign-off)
- Stage 3: Provision (run provisioning workflow)
- Full audit trail of who approved what and when

**Setup Steps:**
1. Create Azure DevOps project in organization

2. Import provisioning scripts to Git repository:
   ```
   /code/inbound-provisioning/
   ├── Run-LifecycleProvisioningWorkflow.ps1
   ├── AttributeMapping-lifecycle.psd1
   ├── data/
   │   └── hr-export-<date>.csv
   └── azure-pipelines.yml
   ```

3. Create `azure-pipelines.yml` with multi-stage pipeline:
   ```yaml
   trigger:
     schedule:
     - cron: "0 2 * * *"  # Daily at 2 AM
       displayName: Daily Provisioning
       branches:
         include:
         - main
   
   pr: none  # Don't run on pull requests
   
   variables:
     TENANT_ID: $(TenantId)  # Set in pipeline library
     PROVISIONING_LOG_PATH: '$(Build.ArtifactStagingDirectory)/logs'
   
   stages:
   - stage: Validate
     displayName: 'Validate Schema & Connectivity'
     jobs:
     - job: SchemaValidation
       displayName: 'Check CSV & Permissions'
       steps:
       - checkout: self
       - task: PowerShell@2
         displayName: 'Validate HR Export'
         inputs:
           targetType: 'inline'
           script: |
             $csv = Import-Csv "./data/hr-export-*.csv"
             if ($csv.Count -eq 0) { throw "No records in export" }
             Write-Host "##[section]Found $($csv.Count) records in export"
             
             # Check required columns exist
             $required = @('mail', 'mailNickname', 'givenName', 'surname', 'jobtitle')
             $missing = $required | Where-Object { $_ -notin $csv[0].PSObject.Properties.Name }
             if ($missing) { throw "Missing columns: $($missing -join ', ')" }
             Write-Host "##[section]All required columns present"
       
       - task: AzurePowerShell@5
         displayName: 'Test Graph API Connectivity'
         inputs:
           azureSubscription: 'ProductionSubscription'
           scriptType: 'InlineScript'
           inline: |
             # Test connection to Graph API
             $token = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
             $header = @{ Authorization = "Bearer $token" }
             $result = Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000003'" -Headers $header
             Write-Host "##[section]Graph API connectivity OK (found $(($result.value).Count) service principals)"
   
   - stage: ApprovalGate
     displayName: 'Await Approval'
     dependsOn: Validate
     condition: succeeded()
     pool: server
     jobs:
     - job: ManualValidation
       displayName: 'Manager Sign-Off Required'
       timeoutInMinutes: 1440  # 24 hours to approve
       steps:
       - task: ManualValidation@0
         inputs:
           instructions: 'Review provisioning run and approve to proceed. Check: HR export date, record count, manager assignments.'
           onTimeout: 'reject'
   
   - stage: Provision
     displayName: 'Run Provisioning'
     dependsOn: ApprovalGate
     condition: succeeded()
     jobs:
     - job: ExecuteProvisioning
       displayName: 'Execute Lifecycle Provisioning'
       steps:
       - checkout: self
       
       - task: AzurePowerShell@5
         displayName: 'Run Provisioning Workflow'
         inputs:
           azureSubscription: 'ProductionSubscription'
           scriptType: 'FilePath'
           scriptPath: '$(Build.SourcesDirectory)/code/inbound-provisioning/Run-LifecycleProvisioningWorkflow.ps1'
           scriptArguments: |
             -TenantId $(TENANT_ID) `
             -CsvPath "$(Build.SourcesDirectory)/data/hr-export-*.csv" `
             -LogPath "$(PROVISIONING_LOG_PATH)"
       
       - task: PublishBuildArtifacts@1
         displayName: 'Archive Provisioning Logs'
         inputs:
           pathToPublish: '$(PROVISIONING_LOG_PATH)'
           artifactName: 'ProvisioningLogs-$(Build.BuildId)'
           publishLocation: 'Container'
       
       - task: AzureFileCopy@4
         displayName: 'Archive Logs to Compliance Storage'
         inputs:
           SourcePath: '$(PROVISIONING_LOG_PATH)'
           azureSubscription: 'ProductionSubscription'
           Destination: 'AzureBlob'
           storage: 'complianceaudit'
           ContainerName: 'provisioning-logs'
           BlobPrefix: '$(Build.BuildNumber)/'
   
   - stage: PostProvisioning
     displayName: 'Notify & Archive'
     dependsOn: Provision
     condition: always()
     jobs:
     - job: Notification
       displayName: 'Send Summary'
       steps:
       - task: PublishBuildArtifacts@1
         displayName: 'Publish Final Summary'
         inputs:
           pathToPublish: '$(PROVISIONING_LOG_PATH)/summary.json'
           artifactName: 'ProvisioningSummary'
       
       - task: PostBuildCleanup@3
   ```

4. Configure pipeline security:
   - Store secrets in Azure Key Vault (never in code)
   - Create Service Connection with Managed Identity
   - Require approval before merging CSV changes to main branch
   - Enable branch protection policy on main

5. Set up approval flow in Azure DevOps:
   - Required approvers: IT Manager, Compliance Officer
   - Auto-reject if not approved within 24 hours
   - Log all approval decisions to audit table

**Advantages:**
- Complete audit trail: git commit, approval, execution, results
- Version control for all scripts and CSV exports
- Rollback capability via git history
- Integrated with enterprise change management
- Mature tooling for retry, timeout, and error handling
- Scales to multiple provisioning runs per day

**Considerations:**
- Requires Azure DevOps expertise or hiring DevOps engineer
- More infrastructure to maintain (pipeline agents, service connections)
- Longer setup time but most robust for regulated environments

**Estimated cost:** $50-200/month (depends on pipeline duration and storage)
**Estimated timeline:** 3-4 weeks to set up, test, and deploy

---

## Integration with HR Systems (CSV-Based)

This guide assumes you are using **CSV file export** as your integration method. This is common for:
- Custom or legacy HR systems without APIs
- Organizations that prefer batch processing over real-time sync
- Scenarios where HR exports files to SFTP or file share
- Need for manual review/approval before provisioning

If your HR system has a direct SCIM connector (Workday, SAP, ADP), use that instead—see [HR-driven provisioning](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/what-is-hr-driven-provisioning).

### CSV-Based Data Flow
1. **HR System Export Phase:**
   - HR system exports employee delta (new hires, changes, terminations) to CSV
   - Export file is placed in accessible location: SFTP, file share, email, or Blob Storage
   - File follows agreed schema: mail, givenName, surname, jobtitle, manager, etc.

2. **File Transport Phase:**
   - Provisioning automation polls for new export file
   - File is downloaded/retrieved from source location
   - Validated for schema and completeness before processing

3. **Transformation Phase:**
   - Validates CSV schema (required: mail, givenName, surname, etc.)
   - Applies business rules: UPN uniqueness, manager existence, org validation
   - Transforms to `scim-lifecycle-template.csv` format with Entra-specific fields
   - Optional: Human approval gate before proceeding

4. **Provisioning Phase:**
   - Invokes `Run-LifecycleProvisioningWorkflow.ps1`
   - Bulk uploads users to Entra via SCIM API
   - Assigns managers and security groups
   - Captures detailed provisioning log

5. **Audit Phase:**
   - Archive CSV and provisioning log to immutable storage
   - Log all actions to audit table (who, what, when, why)
   - Generate compliance report for records retention

### System-Specific Guidance (CSV Export)

**Important:** The systems listed below have **direct SCIM connectors available**. For best results, use those instead of CSV export. This section is for organizations that cannot use direct SCIM for technical or business reasons.

**Workday (CSV-based alternative to SCIM):**
- Export employee feed via Workday Report Writer or REST API
- Export to SFTP or Blob Storage on daily schedule
- Fields needed: employeeId, firstName, lastName, email, manager, jobtitle
- Format as CSV with headers matching your template
- **Better option:** Use [Workday SCIM connector](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/what-is-hr-driven-provisioning) for real-time provisioning

**SAP SuccessFactors (CSV-based alternative to SCIM):**
- Use SAP Report Center to export employee data
- Export to SFTP or file share daily
- Fields needed: employeeId, firstName, lastName, email, manager, jobtitle
- Use third-party tool to convert to CSV if needed
- **Better option:** Use SAP SuccessFactors SCIM connector for real-time provisioning

**ADP (CSV-based alternative to SCIM):**
- Export payroll or HR data to CSV via ADP reporting
- Place file on SFTP or Blob Storage
- Fields needed: employeeId, firstName, lastName, email, manager, jobtitle
- **Better option:** Use ADP SCIM connector with webhook for real-time events

**Generic/Legacy/Custom HR Systems:**
- Export from HR system to CSV (standard format)
- Deliver to SFTP, file share, email, or Blob Storage
- Use template transformation script to map fields to standard names
- Consider Data Factory for complex field transformations
- This is the primary use case for this guide

---

## Security & Compliance Requirements

### Authentication & Authorization
- **Use Managed Identity** (System-Assigned) for automation account
  - No passwords or app credentials embedded in scripts
  - Automatic credential rotation by Azure
  - Audit log tracks identity of all provisioning actions

- **Application Credentials** (if Managed Identity not available):
  - Store in Azure Key Vault only
  - Use certificate-based auth (not client secret)
  - Rotate every 90 days
  - Never log or display credentials

- **Conditional Access Policy**:
  ```
  Users: Service Principal for provisioning
  Cloud Apps: Microsoft Graph
  Conditions: Mark as compliant device only
  Grant: Require MFA (via Managed Identity) OR Certificate
  Session: 1 hour max duration
  ```

### Data Protection
- **At Rest:**
  - Enable AES-256 encryption on Azure Blob Storage
  - Enable Transparent Data Encryption (TDE) on Azure SQL (if used)
  - Encrypt CSV exports with GPG before archival

- **In Transit:**
  - Enforce TLS 1.2+ (already default for Graph API)
  - Use Azure Private Endpoints for all traffic (avoid internet)
  - Certificate pinning for critical APIs (optional, advanced)

- **Access Control:**
  - RBAC on Storage Account: Only provisioning automation can read/write
  - RBAC on Automation Account: Only IT Ops team can modify runbooks
  - Key Vault: Only provisioning identity can access secrets

### Audit & Compliance Logging
- **What to Log:**
  - Every user created: UPN, email, manager, job title
  - Every user updated: changed attributes, old/new values
  - Every user deleted: reason, approved by, timestamp
  - Every provisioning failure: error code, affected user, retry attempts
  - Every manual intervention: who, what, when, why

- **Where to Store:**
  - Azure AD Audit Logs: Automatic for all Entra changes (30 days retention)
  - Azure Log Analytics: Provisioning runbook logs (customize retention)
  - Immutable Blob Storage: Archive all logs for 7+ years (regulatory requirement)
  - Optional: SIEM (Splunk, Sentinel) for real-time alerting

- **Retention Policy Example:**
  - Hot storage (Blob): 90 days
  - Cool storage (Blob): 1 year
  - Archive storage (Blob): 7 years
  - Cost: ~$20/month for 7-year archival of daily logs

### Error Handling & Monitoring
- **Transient Failures** (auto-retry 3x with exponential backoff):
  - HTTP 429 (throttled): Wait 60s, retry
  - HTTP 500, 502, 503: Wait 30s, retry
  - Connection timeout: Wait 30s, retry
  - Graph API temporary unavailability

- **Permanent Failures** (alert and stop):
  - HTTP 400 (bad request): Schema validation error, require manual fix
  - HTTP 401 (unauthorized): Authentication failed, verify credentials
  - HTTP 403 (forbidden): Permission denied, verify RBAC
  - CSV validation failed: Required field missing, invalid email format
  - Manager not found: UPN specified but doesn't exist in Entra

- **Alert Thresholds:**
  - Any HTTP 401 or 403 → **Immediate alert** (security issue)
  - >5% records failed → **Warning alert** (data quality issue)
  - Any deprovisioning action → **Manual approval required** (before execution)
  - Provisioning duration >10 minutes → **Warning alert** (performance issue)
  - Job runs more than once per day → **Blocking alert** (prevent duplicates)

- **Alerting Channels:**
  - Email: IT Operations team, Compliance Officer
  - Teams: #provisioning-alerts channel (auto-post summaries)
  - PagerDuty: Escalate auth failures to on-call engineer
  - ServiceNow: Create ITSM incident for failures

---

## Scaling for Large Deployments

### Current Local Demo Limits
- **Users per run:** 100-500 (limited by device auth timeout ~15 min)
- **Records/second:** 5-10 (limited by laptop CPU/network)
- **Graph API:** 1,000 requests/minute throttle
- **SCIM bulk upload:** 5,000 users per batch

### For 10,000+ Users

**Batch Processing:**
- Split CSV into chunks of 5,000 users
- Schedule multiple provisioning jobs in parallel (30-min offset)
- Example for 25,000 users:
  - Job 1: Users 0-5,000 (2 AM)
  - Job 2: Users 5,000-10,000 (2:30 AM)
  - Job 3: Users 10,000-15,000 (3:00 AM)
  - etc.

**Application Authentication:**
- Use client credentials flow (app ID + secret/cert) instead of device code
- Supports non-interactive batch operations
- No user login required
- Rate limit: 60+ requests/second possible (vs 5-10 for user auth)

**Data Validation Pre-Upload:**
- Validate before sending to Entra (fail fast principle)
- Check: UPN uniqueness, required fields present, email format valid
- Manager lookup: verify all manager UPNs exist
- Deduplicate: if same UPN appears twice in CSV, use last occurrence

**Multi-Region Deployments:**
- If managing multiple Entra tenants (e.g., North America, EMEA, APAC)
- Deploy separate Automation Accounts in each region
- Synchronize provisioning policies via Git
- Stagger runs to avoid global throttling conflicts

**Performance Optimization:**
- Use Graph API batch requests (up to 20 operations per batch)
- Parallelize manager assignments (separate job after user creation)
- Skip retries for user-already-exists errors (check before upload)
- Monitor Graph API throttling: log rate limits and adjust batch size

---

## Migration Path: Demo to Production

### Phase 1: Planning & Assessment (Week 1-2)
**Goals:**
- Decide on deployment option (Automation Account recommended)
- Assess current HR system export capability
- Define governance model (who approves, how often)
- Identify security/compliance requirements

**Tasks:**
- [ ] Interview IT Operations: What's acceptable downtime? What SLA?
- [ ] Interview HR/Payroll: When is export available? Format?
- [ ] Interview Compliance/Legal: How long must logs be retained?
- [ ] Design error escalation process
- [ ] Plan training for ops team

### Phase 2: Development & Testing (Week 3-5)
**Goals:**
- Set up test environment (Dev tenant or isolated test OU)
- Adapt provisioning scripts for cloud-based execution
- Validate HR system integration

**Tasks:**
- [ ] Create Dev Azure Automation Account
- [ ] Upload provisioning scripts and test
- [ ] Configure logging and monitoring
- [ ] Run end-to-end test with 100 test users
- [ ] Test error scenarios: bad CSV, throttling, auth failure
- [ ] Measure performance: time to provision 100, 500, 1000 users
- [ ] Document runbook parameters and error codes

### Phase 3: Integration with HR (Week 5-6)
**Goals:**
- Connect to real HR system export
- Validate CSV format and data quality

**Tasks:**
- [ ] Set up API/SFTP connection to HR system
- [ ] Run HR export to Blob Storage
- [ ] Validate CSV schema with production data
- [ ] Run provisioning in dry-run mode (WhatIf flag)
- [ ] Review generated CSV: are all users there? Any oddities?
- [ ] Approve fields mapping (UPN format, email policy, etc.)

### Phase 4: Pilot with Real Users (Week 7-8)
**Goals:**
- Run provisioning with real user creation
- Gather feedback from early adopter group

**Tasks:**
- [ ] Identify pilot group (e.g., IT department, 50-100 people)
- [ ] Create users for pilot group only (filter CSV or separate run)
- [ ] Users sign into Office 365, Teams, SharePoint
- [ ] Gather feedback: any issues with auto-provisioned accounts?
- [ ] Monitor for 1-2 weeks for any edge cases or failures
- [ ] Adjust script if needed (UPN format, licensing, etc.)

### Phase 5: Full Rollout (Week 9+)
**Goals:**
- Enable provisioning for all departments
- Decommission manual provisioning process

**Tasks:**
- [ ] Full provisioning run for all remaining users
- [ ] Disable legacy provisioning process (document old process)
- [ ] Train IT Ops on monitoring/troubleshooting
- [ ] Establish on-call rotation for provisioning alerts
- [ ] Create runbook for manual emergency provisioning
- [ ] Archive logs and transition to operations team

### Post-Rollout: Operations & Maintenance (Ongoing)
**Tasks:**
- [ ] Daily monitoring: check runbook success/failure
- [ ] Weekly review: any unusual patterns?
- [ ] Monthly compliance report: new users, deletions, failures
- [ ] Quarterly review: adjust batch sizes, performance optimization
- [ ] Annually: audit provisioning policies against security standards

---

## Cost Estimation (Azure)

Assuming: 5,000 users, daily provisioning runs, 2-5 minute runtime

### Option 1: Automation Account (Recommended)
| Component | Unit Cost | Monthly | Notes |
|-----------|-----------|---------|-------|
| Automation Account | $0.002/min | $2.88 | 2 min avg × 30 days |
| Log Analytics | $0.30/GB | $15-30 | 500MB-1GB logs/month |
| Key Vault | $0.60/vault | $0.60 | Per month, requests included |
| Blob Storage | $0.024/GB | $5-10 | 200-400GB archives/year = $20-40/yr |
| **Total** | | **$24-44** | |

### Option 2: Logic App + Azure Function
| Component | Unit Cost | Monthly | Notes |
|-----------|-----------|---------|-------|
| Logic App | $0.20/run | $6 | 30 runs × $0.20 |
| Azure Function | $0.000002/exec | $1-3 | Depends on duration |
| App Service Plan | $15-30/mo | $15-30 | Min. B1 plan |
| Log Analytics | $0.30/GB | $15-30 | 500MB-1GB logs |
| Storage | | $5 | Similar to Option 1 |
| **Total** | | **$42-74** | |

### Option 3: CI/CD Pipeline with DevOps
| Component | Unit Cost | Monthly | Notes |
|-----------|-----------|---------|-------|
| DevOps Pipeline | Free | $0 | Microsoft-hosted agents free for public repos |
| Self-hosted agents | $40/agent | $40-80 | If private repo: 1-2 agents needed |
| Artifact storage | $2/100GB | $2-5 | Pipeline artifacts + logs |
| Log Analytics | $0.30/GB | $15-30 | 500MB-1GB logs |
| Storage | | $5 | Similar to Option 1 |
| **Total** | | **$62-120** | Or $15-35 if using public repo |

### Scaling Costs (25,000 users, 5x current)
- **Automation Account:** +$10 = $34-54 (longer runtimes, more logs)
- **Logic App:** +$25 = $67-99 (more function executions)
- **CI/CD:** +$20 = $82-140 (more pipeline runs, storage)

---

## Recommended Path Forward for Customers

### Immediate (This Week)
1. Decide: Use Automation Account (simplest for most organizations)
2. Assess HR system: Can it export daily? Format? Location?
3. Budget: Allocate 3-4 weeks for implementation
4. Team: Identify IT Ops owner, Azure admin, HR contact

### Short-term (Week 1-2)
1. Create Azure Automation Account in production subscription
2. Set up managed identity and grant Entra permissions
3. Adapt provisioning scripts for cloud execution
4. Test in dev environment with 100-500 users

### Medium-term (Week 3-6)
1. Integrate HR system export to Blob Storage
2. Run pilot with real users (50-100 people)
3. Validate manager assignments and lifecycle policies
4. Build monitoring and alerting

### Long-term (Week 7+)
1. Full rollout to all users
2. Decommission laptop-based provisioning
3. Hand off to IT Operations
4. Establish SLA and escalation process

---

## Next Steps Checklist for Customer

**Strategy Questions:**
- [ ] How often does HR data change? (Daily, weekly, real-time?)
- [ ] Where is HR data currently stored? (On-premises, cloud SaaS, SFTP?)
- [ ] Who owns provisioning today? (HR, IT, Shared Services?)
- [ ] What's the current provisioning SLA? (How long can delays be tolerated?)
- [ ] Do you have change control process? (Approvals required before deployment?)
- [ ] Compliance requirements? (SOC 2, ISO 27001, FedRAMP, HIPAA?)

**Technical Readiness:**
- [ ] Do you have Azure subscription for production?
- [ ] Who can manage Azure Automation Accounts? (Need Azure admin)
- [ ] Can HR system export daily CSV or API? (Test export capability)
- [ ] Do you have Log Analytics workspace? (For monitoring)
- [ ] Can you enable managed identities? (Ask Azure security team)

**Governance Setup:**
- [ ] Who approves provisioning runs? (IT Manager, Compliance Officer?)
- [ ] How do you handle provisioning errors? (Who gets paged?)
- [ ] How long must logs be retained? (7 years for financial orgs?)
- [ ] Do you need audit trail of who ran provisioning? (Yes, always document)

---

## References & Resources

**Microsoft Entra HR-Driven Provisioning:**
- [HR-driven provisioning overview](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/what-is-hr-driven-provisioning) (**Use SCIM connectors if available instead of CSV**)
- [Inbound Provisioning API (CSV bulk upload)](https://learn.microsoft.com/en-us/graph/api/synchronization-synchronizationjob-post-bulkupload?view=graph-rest-beta)
- [SCIM User Provisioning](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/use-scim-to-provision-users-and-groups)
- [Lifecycle Workflows](https://learn.microsoft.com/en-us/entra/id-governance/lifecycle-workflows-overview)

**Azure Automation:**
- [Create Runbooks](https://learn.microsoft.com/en-us/azure/automation/learn/automation-tutorial-runbook-textual-powershell)
- [Managed Identities](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview)
- [Run as Account deprecated](https://learn.microsoft.com/en-us/azure/automation/migrate-from-runas-to-managed-identity)

**Security & Compliance:**
- [Azure Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/overview)
- [Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/overview)
- [Microsoft Entra Audit Logs](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-audit-logs)

**Performance & Scaling:**
- [Microsoft Graph Throttling](https://learn.microsoft.com/en-us/graph/throttling)
- [SCIM Batch Operations](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/how-provisioning-works#bulk-upload)
- [Azure Automation Quotas](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#automation-limits)
