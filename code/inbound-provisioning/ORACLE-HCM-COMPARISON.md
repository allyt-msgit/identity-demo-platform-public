# Oracle HCM Connector Comparison: What We Built vs Microsoft Learn Pattern

This note explains whether the current implementation matches the Oracle HCM Microsoft Entra guidance and highlights differences to call out to customers.

Reference:
- [Configure Oracle HCM for automatic user provisioning](https://learn.microsoft.com/en-us/entra/identity/saas-apps/oracle-hcm-provisioning-tutorial#configure-gallery-application)

## Bottom Line

Yes, this implementation follows the same **core API-driven provisioning pattern** used in the Oracle HCM guidance for the CSV path:
- HR export data -> CSV -> SCIM bulk payload -> Microsoft Entra inbound provisioning API.

## What Is Aligned

1. API-driven inbound provisioning to Microsoft Entra is implemented.
2. CSV-to-SCIM transformation is implemented.
3. Initial/full and repeat runs are supported.
4. Lifecycle attributes (hire/leave date, usage location) are included.
5. Provisioning schema extension and mapping updates are included.

## Differences to Call Out to Customers

1. Oracle extraction layer is not part of this repo.
- This solution assumes CSV already exists.
- The Oracle side (HCM Extracts, BI Publisher, OIC, ATOM feed subscription) must still be implemented in customer environment.

2. Oracle delta/event ingestion is not implemented.
- Current flow is file-based reruns.
- ATOM feed-based near real-time processing would require a custom module.

3. Gallery app creation/configuration is not automated by script.
- Scripts require an already configured provisioning app (`ServicePrincipalId`, synchronization job).

4. Hybrid target path is not implemented.
- Current implementation is cloud-first to Microsoft Entra.
- On-prem AD provisioning agent path is out of scope in current scripts.

5. Writeback to Oracle HCM is not implemented.
- This build is inbound only (HR -> Entra).
- Outbound writeback (Entra -> Oracle) would be a separate provisioning job.

6. Manager assignment is custom post-processing.
- Manager updates are applied after upload by Graph API call.
- This is valid, but custom behavior beyond base mapping.

7. Authentication defaults are demo-friendly.
- Device auth is used in interactive runs.
- Production should use certificate/app auth or managed identity.

8. Production controls are documented, not fully deployed here.
- Scheduling, monitoring, approval gates, and incident integration are in design guidance.
- Customer still needs to implement these in their tenant/subscription.

## Customer-Friendly Positioning

Use this message with customers:

"We implemented the same Microsoft API-driven Oracle HCM integration pattern for CSV-based provisioning into Entra. The remaining work is environment-specific operationalization: Oracle export/delta integration, production authentication, scheduling/monitoring, governance approvals, and optional writeback."

## Repo Evidence

- Main workflow: `Run-LifecycleProvisioningWorkflow.ps1`
- CSV to SCIM upload: `Invoke-HRInboundProvisioning.ps1`
- Lifecycle mapping: `AttributeMapping-lifecycle.psd1`
- Schema updates: `Update-ProvisioningJobSchema.ps1`
- Demo runbook: `DEMO-FLOW.md`
- Production guidance: `GO-LIVE-GUIDE.md`
