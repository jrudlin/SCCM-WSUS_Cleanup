# SCCM WSUS Cleanup
Runs a WSUS database cleaup on SCCM Software Update Point servers where WSUS is installed. Runs on top tier (CAS) or lower tier (Primary Site) WSUS servers.

Should be deployed/implemented as an SCCM Configuration Baseline/Item to a dynamic Collection containing all SCCM Site Servers.
Dynamic Collection membership rule:
select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client from SMS_R_System where SMS_R_System.SystemRoles = "SMS Site Server"
