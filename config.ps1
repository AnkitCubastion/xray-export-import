# ===================================================================
# config.ps1 — central configuration for the Xray migration toolkit.
# Edit the values below, then run .\Run-Migration.ps1
# This file returns a hashtable; it contains NO secrets.
# ===================================================================

@{
    # ---- SOURCE: Jira Server 8.4.0 + Xray Server/DC ----
    # Production source of record (confirmed). QA alt: https://dta-jira-qa.jpn.dc.tbintra.net/jira
    JiraServerUrl    = "https://dta-jira.jpadc.corpintra.net/jira"
    ServerProjectKey = "MFTBCTRKD"
    RavenVersion     = "1.0"          # 1.0 is safe on Jira 8.4.0 (2.0 renames /step -> /steps)
    PageSize         = 100
    ServerThrottleMs = 0              # raise (e.g. 100) if the server pushes back
    AllowInsecureSource = $true       # the internal host uses a self-signed TLS cert

    # ---- TARGET: Jira Cloud + Xray Cloud ----
    # !!! REPLACE the placeholder below with YOUR Jira Cloud SITE URL — the
    # address shown in your browser when you're in Jira (ends in .atlassian.net),
    # e.g. https://cubastion.atlassian.net. This is NOT your email; your login
    # email is entered at the prompt (or via $env:JIRA_CLOUD_EMAIL).
    JiraCloudUrl     = "https://ankitcubastion.atlassian.net"
    CloudProjectKey  = "TEST"         # MUST have Xray Cloud installed + the 6 Xray issue types on its scheme
    XrayCloudBase    = "https://xray.cloud.getxray.app"   # regional: https://us. / https://eu. / https://au.

    # ---- Export options ----
    IncludeChangelog = $true          # backup only (Cloud cannot rewrite history)
    IncludeWorklog   = $true

    # ---- Import options ----
    # Full lossless set. Add "fields" to promote native Cloud fields and
    # "worklogs" to re-create worklogs (both optional, best-effort).
    Steps            = @("issues","associations","attachments","comments","links","results")
    CloudThrottleMs  = 200
    XrayThrottleMs   = 1200           # ~300 req/5min Standard limit, with headroom for retries
    EmbedMetadataInDescription = $true
    UsePreconditionGraphql     = $true
    SubExecFallback  = "TestExecution"   # "TestExecution" | "Skip"
}
