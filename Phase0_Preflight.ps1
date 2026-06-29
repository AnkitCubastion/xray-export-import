# ===================================================================
# PHASE 0 — PREFLIGHT / GO-NO-GO CHECK
# ===================================================================
#
# Validates EVERYTHING the migration depends on, BEFORE you spend hours
# exporting/importing ~11k issues. It is read-only (creates nothing).
#
# It checks, and prints a clear PASS/FAIL for each:
#   SOURCE (Jira Server 8.4.0 + Xray Server/DC)
#     - TLS trust to the self-signed host
#     - Basic auth works (/rest/api/2/myself)
#     - Xray raven API reachable (/rest/raven/1.0/api/settings/...)
#     - Per-type issue counts in the source project (your reconciliation baseline)
#   TARGET (Jira Cloud + Xray Cloud)
#     - Jira Cloud auth works (/rest/api/3/myself)
#     - Xray Cloud auth works (/api/v2/authenticate)
#     - *** The 6 Xray issue types EXIST on the target project's scheme ***
#       (Precondition, Test, Test Set, Test Execution, Test Plan, Sub Test
#        Execution) — this is the #1 cause of the past
#        "Specify a valid issue type" 400s.
#     - Issue link types available
#
# Exit code 0 = all critical checks passed (safe to run Phase 1/2).
# Exit code 1 = at least one CRITICAL check failed (fix before proceeding).
# ===================================================================

[CmdletBinding()]
param(
    [string]$JiraServerUrl    = "https://dta-jira.jpadc.corpintra.net/jira",
    [string]$ServerProjectKey = "MFTBCTRKD",
    [string]$RavenVersion     = "1.0",
    [string]$JiraCloudUrl     = "https://ankitanku090701.atlassian.net",
    [string]$CloudProjectKey  = "TEST",
    [string]$XrayCloudBase    = "https://xray.cloud.getxray.app",   # or us/eu/au regional host
    [switch]$AllowInsecureSource = $true,                            # trust the self-signed source cert
    [switch]$SkipSource,                                             # only check the Cloud side
    [switch]$SkipTarget                                              # only check the Server side
)

. "$PSScriptRoot\XrayMig.Common.ps1"
Initialize-XrayMig

$reportDir = Join-Path $PSScriptRoot "export\$ServerProjectKey"
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
Set-LogFiles -LogFile (Join-Path $reportDir "_preflight.log") -ErrorFile (Join-Path $reportDir "_preflight_errors.log")

# Cloud type names Xray uses (note: Server "Pre-Condition" -> Cloud "Precondition")
$requiredCloudTypes = @("Precondition","Test","Test Set","Test Execution","Test Plan","Sub Test Execution")
$serverTypes        = @("Pre-Condition","Test","Test Set","Test Execution","Test Plan","Sub Test Execution")

$results = [System.Collections.Generic.List[object]]::new()
function Add-Check {
    param([string]$Area,[string]$Name,[bool]$Ok,[string]$Detail,[bool]$Critical = $true)
    $results.Add([pscustomobject]@{ Area=$Area; Check=$Name; Result=$(if($Ok){"PASS"}else{"FAIL"}); Critical=$Critical; Detail=$Detail })
    $lvl = if ($Ok) { "SUCCESS" } elseif ($Critical) { "ERROR" } else { "WARN" }
    Write-Log ("[{0}] {1} — {2}" -f $(if($Ok){"PASS"}else{"FAIL"}), $Name, $Detail) $lvl
}

# ===================================================================
# SOURCE CHECKS
# ===================================================================
if (-not $SkipSource) {
    Write-Section "SOURCE — JIRA SERVER 8.4.0 + XRAY"
    if ($AllowInsecureSource) { Enable-InsecureSource -Url $JiraServerUrl }

    $srvUser = Get-PlainValue  -EnvVarName "XRAY_SRV_USER" -Prompt "Enter Jira Server Username"
    $srvPass = Get-SecretValue -EnvVarName "XRAY_SRV_PASS" -Prompt "Enter Jira Server Password"
    $srvHeaders = New-BasicAuthHeader -User $srvUser -Secret $srvPass
    $srvPass = $null

    try {
        $me = Invoke-Api -Uri "$JiraServerUrl/rest/api/2/myself" -Headers $srvHeaders -Channel "server"
        Add-Check "SOURCE" "Jira Server login" $true "Connected as $($me.displayName) ($($me.name))"
    } catch {
        Add-Check "SOURCE" "Jira Server login" $false $_.Exception.Message
    }

    # Raven reachability — a cheap authenticated raven call.
    $ravenBase = "$JiraServerUrl/rest/raven/$RavenVersion/api"
    try {
        $null = Invoke-Api -Uri "$ravenBase/settings/teststatuses" -Headers $srvHeaders -Channel "server"
        Add-Check "SOURCE" "Xray raven API reachable" $true "$ravenBase responded"
    } catch {
        # Some installs lock that endpoint down; fall back to a per-test probe later.
        Add-Check "SOURCE" "Xray raven API reachable" $false "Could not read $ravenBase/settings/teststatuses :: $($_.Exception.Message)" $false
    }

    # Per-type counts (reconciliation baseline).
    Write-Log "Counting source issues per Xray type (this is your reconciliation baseline)..."
    $counts = [ordered]@{}
    $grand = 0
    foreach ($t in $serverTypes) {
        try {
            $jql = "project = `"$ServerProjectKey`" AND issuetype = `"$t`""
            $enc = [uri]::EscapeDataString($jql)
            $r = Invoke-Api -Uri "$JiraServerUrl/rest/api/2/search?jql=$enc&maxResults=0" -Headers $srvHeaders -Channel "server"
            $counts[$t] = [int]$r.total; $grand += [int]$r.total
            Write-Log ("  {0,-20} : {1}" -f $t, $r.total) "INFO"
        } catch {
            $counts[$t] = -1
            Write-Log "  $t : count failed — $($_.Exception.Message)" "WARN"
        }
    }
    Add-Check "SOURCE" "Project '$ServerProjectKey' issue counts" ($grand -gt 0) "Total Xray issues = $grand"
    $counts | ForEach-Object { $_ } | Out-Null
    [pscustomobject]$counts | Export-Csv -Path (Join-Path $reportDir "_source_counts.csv") -NoTypeInformation -Encoding UTF8
}

# ===================================================================
# TARGET CHECKS
# ===================================================================
if (-not $SkipTarget) {
    Write-Section "TARGET — JIRA CLOUD + XRAY CLOUD"

    try { Confirm-BaseUrl -Url $JiraCloudUrl -Name "JiraCloudUrl" | Out-Null }
    catch { Add-Check "TARGET" "Jira Cloud URL valid" $false $_.Exception.Message; $SkipTarget = $true }
}
if (-not $SkipTarget) {
    $cloudEmail = Get-PlainValue  -EnvVarName "JIRA_CLOUD_EMAIL" -Prompt "Enter Jira Cloud Email"
    $cloudToken = Get-SecretValue -EnvVarName "JIRA_CLOUD_TOKEN" -Prompt "Enter Jira Cloud API Token"
    $cloudHeaders = New-BasicAuthHeader -User $cloudEmail -Secret $cloudToken
    $cloudToken = $null

    try {
        $me = Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/myself" -Headers $cloudHeaders -Channel "cloud-jira"
        Add-Check "TARGET" "Jira Cloud login" $true "Connected as $($me.displayName) <$($me.emailAddress)> accountId=$($me.accountId)"
    } catch {
        Add-Check "TARGET" "Jira Cloud login" $false $_.Exception.Message
    }

    # Resolve the issue types ON THE TARGET PROJECT'S SCHEME (paginated).
    $cloudTypeNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $cloudTypeMap = @{}
    try {
        $startAt = 0
        do {
            $resp = Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/issue/createmeta/$CloudProjectKey/issuetypes?startAt=$startAt&maxResults=50" -Headers $cloudHeaders -Channel "cloud-jira"
            $vals = @()
            if ($resp.PSObject.Properties['values'])     { $vals = @($resp.values) }
            elseif ($resp.PSObject.Properties['issueTypes']) { $vals = @($resp.issueTypes) }
            elseif ($resp -is [System.Array])            { $vals = @($resp) }
            foreach ($it in $vals) { if ($it.name) { [void]$cloudTypeNames.Add($it.name); $cloudTypeMap[$it.name] = $it.id } }
            $got = $vals.Count
            $startAt += $got
            $total = if ($resp.PSObject.Properties['total']) { [int]$resp.total } else { $startAt }
        } while ($got -gt 0 -and $startAt -lt $total)
        Add-Check "TARGET" "Read project issue-type scheme" ($cloudTypeNames.Count -gt 0) "Found $($cloudTypeNames.Count) types: $(( $cloudTypeNames ) -join ', ')"
    } catch {
        Add-Check "TARGET" "Read project issue-type scheme" $false "createmeta failed for '$CloudProjectKey' :: $($_.Exception.Message)"
    }

    # *** THE CRITICAL CHECK *** — every required Xray type must be present.
    $missing = @()
    foreach ($t in $requiredCloudTypes) { if (-not $cloudTypeNames.Contains($t)) { $missing += $t } }
    if ($missing.Count -eq 0) {
        Add-Check "TARGET" "Xray issue types on project '$CloudProjectKey'" $true "All present: $($requiredCloudTypes -join ', ')"
    } else {
        Add-Check "TARGET" "Xray issue types on project '$CloudProjectKey'" $false "MISSING: $($missing -join ', '). Install/enable Xray Cloud on this project and add these types to its issue-type scheme. THIS is why imports previously failed with 'Specify a valid issue type'."
    }

    # Xray Cloud auth.
    $xrayClientId     = Get-PlainValue  -EnvVarName "XRAY_CLIENT_ID"     -Prompt "Enter Xray Cloud Client Id"
    $xrayClientSecret = Get-SecretValue -EnvVarName "XRAY_CLIENT_SECRET" -Prompt "Enter Xray Cloud Client Secret"
    try {
        $null = Set-XrayAuth -BaseUrl $XrayCloudBase -ClientId $xrayClientId -ClientSecret $xrayClientSecret
        $xrayClientSecret = $null
        Add-Check "TARGET" "Xray Cloud authentication" $true "Token acquired from $XrayCloudBase"
    } catch {
        Add-Check "TARGET" "Xray Cloud authentication" $false "$($_.Exception.Message). If this says 'data is in another region', use the regional -XrayCloudBase (us/eu/au)."
    }

    # Issue link types (for the links step).
    try {
        $lt = Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/issueLinkType" -Headers $cloudHeaders -Channel "cloud-jira"
        $names = @($lt.issueLinkTypes | ForEach-Object { $_.name })
        Add-Check "TARGET" "Issue link types" ($names.Count -gt 0) "Available: $($names -join ', ')" $false
    } catch {
        Add-Check "TARGET" "Issue link types" $false $_.Exception.Message $false
    }
}

if ($AllowInsecureSource) { Disable-InsecureSource }

# ===================================================================
# REPORT
# ===================================================================
Write-Section "PREFLIGHT REPORT"
$results | Format-Table Area, Result, Critical, Check, Detail -AutoSize -Wrap
$results | Export-Csv -Path (Join-Path $reportDir "_preflight_report.csv") -NoTypeInformation -Encoding UTF8

$critFails = @($results | Where-Object { $_.Result -eq "FAIL" -and $_.Critical })
$warnFails = @($results | Where-Object { $_.Result -eq "FAIL" -and -not $_.Critical })

Write-Host ""
if ($critFails.Count -eq 0) {
    Write-Host "  RESULT: GO — all critical checks passed." -ForegroundColor Green
    if ($warnFails.Count) { Write-Host "  ($($warnFails.Count) non-critical warning(s) — review above.)" -ForegroundColor Yellow }
    Write-Host "  Next: .\Phase1_Export_Server.ps1 -MaxIssuesPerType 5   (dry run)" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "  RESULT: NO-GO — $($critFails.Count) critical check(s) failed:" -ForegroundColor Red
    foreach ($f in $critFails) { Write-Host "    - [$($f.Area)] $($f.Check): $($f.Detail)" -ForegroundColor Red }
    Write-Host "  Fix these before running the migration." -ForegroundColor Yellow
    exit 1
}
