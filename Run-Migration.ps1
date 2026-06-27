# ===================================================================
# Run-Migration.ps1 — one-stop orchestrator for the Xray Server -> Cloud
#                     migration (MFTBCTRKD -> TEST).
# ===================================================================
#
# Runs, in order, with confirmation prompts between phases:
#   0. Preflight   (Phase0_Preflight.ps1)   — go/no-go checks (read-only)
#   1. Export      (Phase1_Export_Server.ps1)
#   2. Import      (Phase2_Import_Cloud.ps1)
#
# All settings live in .\config.ps1 (edit that first). Credentials are read
# from environment variables if present, otherwise each phase prompts.
#
# Examples:
#   .\Run-Migration.ps1 -DryRun                 # preflight + 5-issue export/import smoke test
#   .\Run-Migration.ps1 -Only Preflight
#   .\Run-Migration.ps1 -Only Export
#   .\Run-Migration.ps1 -Only Import -Steps results
#   .\Run-Migration.ps1                          # full guided run
# ===================================================================

[CmdletBinding()]
param(
    [ValidateSet("All","Preflight","Export","Import")]
    [string]   $Only = "All",
    [string[]] $Steps,              # override Phase 2 steps (e.g. results / issues,associations)
    [switch]   $DryRun,             # 5 issues/type end to end
    [switch]   $NonInteractive,     # do not pause between phases
    [string]   $ConfigPath = "$PSScriptRoot\config.ps1"
)

if (-not (Test-Path $ConfigPath)) { Write-Host "Config not found: $ConfigPath" -ForegroundColor Red; exit 1 }
$cfg = & $ConfigPath

function Confirm-Continue {
    param([string]$Message)
    if ($NonInteractive) { return $true }
    $a = Read-Host "$Message  [Y/n]"
    return ($a -eq "" -or $a -match '^(y|yes)$')
}

$maxPer = if ($DryRun) { 5 } else { 0 }

# ---- 0. PREFLIGHT ----
if ($Only -in @("All","Preflight")) {
    Write-Host "`n=== PREFLIGHT ===" -ForegroundColor Cyan
    & "$PSScriptRoot\Phase0_Preflight.ps1" `
        -JiraServerUrl $cfg.JiraServerUrl -ServerProjectKey $cfg.ServerProjectKey -RavenVersion $cfg.RavenVersion `
        -JiraCloudUrl $cfg.JiraCloudUrl -CloudProjectKey $cfg.CloudProjectKey -XrayCloudBase $cfg.XrayCloudBase `
        -AllowInsecureSource:$cfg.AllowInsecureSource
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Preflight failed (NO-GO). Fix the reported issues before continuing." -ForegroundColor Red
        if ($Only -eq "Preflight") { exit $LASTEXITCODE }
        if (-not (Confirm-Continue "Preflight reported problems. Continue anyway?")) { exit 1 }
    }
    if ($Only -eq "Preflight") { exit 0 }
    if (-not (Confirm-Continue "Proceed to EXPORT?")) { exit 0 }
}

# ---- 1. EXPORT ----
if ($Only -in @("All","Export")) {
    Write-Host "`n=== EXPORT (Phase 1) ===" -ForegroundColor Cyan
    & "$PSScriptRoot\Phase1_Export_Server.ps1" `
        -JiraServerUrl $cfg.JiraServerUrl -ServerProjectKey $cfg.ServerProjectKey -RavenVersion $cfg.RavenVersion `
        -PageSize $cfg.PageSize -ServerThrottleMs $cfg.ServerThrottleMs -MaxIssuesPerType $maxPer `
        -IncludeChangelog $cfg.IncludeChangelog -IncludeWorklog $cfg.IncludeWorklog -AllowInsecureSource $cfg.AllowInsecureSource
    if ($Only -eq "Export") { exit 0 }
    if (-not (Confirm-Continue "Export done. Proceed to IMPORT?")) { exit 0 }
}

# ---- 2. IMPORT ----
if ($Only -in @("All","Import")) {
    Write-Host "`n=== IMPORT (Phase 2) ===" -ForegroundColor Cyan
    $importSteps = if ($Steps) { $Steps } else { $cfg.Steps }
    & "$PSScriptRoot\Phase2_Import_Cloud.ps1" `
        -JiraCloudUrl $cfg.JiraCloudUrl -CloudProjectKey $cfg.CloudProjectKey -XrayCloudBase $cfg.XrayCloudBase `
        -ServerProjectKey $cfg.ServerProjectKey -Steps $importSteps -MaxPerType $maxPer `
        -CloudThrottleMs $cfg.CloudThrottleMs -XrayThrottleMs $cfg.XrayThrottleMs `
        -EmbedMetadataInDescription $cfg.EmbedMetadataInDescription -UsePreconditionGraphql $cfg.UsePreconditionGraphql `
        -SubExecFallback $cfg.SubExecFallback
}

Write-Host "`nDone. Review export\$($cfg.ServerProjectKey)\_import_errors.log and reconcile counts." -ForegroundColor Green
