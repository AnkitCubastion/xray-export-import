# ===================================================================
# Repair-Binaries.ps1 — re-download any attachment/evidence that was
# missed during export (e.g. the wrongly-rejected .html evidence, or a
# transient failure), and patch the issue JSON in place.
#
# WHY: Phase 1 is resumable by skipping issues whose <KEY>.json exists, so
# a binary that failed to download the first time is NOT retried on a normal
# re-run. This pass walks every exported record and recovers only the
# binaries with an empty localPath but a known URL — no full re-export.
#
# Recovered files go under export\<PROJECT>\repaired\<KEY>\ and the JSON's
# localPath is updated to point at them (Phase 2 reads localPath regardless
# of folder). Resumable: re-running only retries what's still missing.
# ===================================================================

[CmdletBinding()]
param(
    [string]$JiraServerUrl    = "https://dta-jira.jpadc.corpintra.net/jira",
    [string]$ServerProjectKey = "MFTBCTRKD",
    [int]   $ServerThrottleMs = 0,
    [bool]  $AllowInsecureSource = $true
)

. "$PSScriptRoot\XrayMig.Common.ps1"
Initialize-XrayMig
if ($AllowInsecureSource) { Enable-InsecureSource -Url $JiraServerUrl }

$exportRoot = Join-Path $PSScriptRoot "export\$ServerProjectKey"
$issuesRoot = Join-Path $exportRoot "issues"
$repairRoot = Join-Path $exportRoot "repaired"
Set-LogFiles -LogFile (Join-Path $exportRoot "_repair.log") -ErrorFile (Join-Path $exportRoot "_repair_errors.log")
if (-not (Test-Path $issuesRoot)) { Write-Host "No export found at $issuesRoot — run Phase 1 first." -ForegroundColor Red; exit 1 }

Write-Section "JIRA SERVER LOGIN"
$srvUser = Get-PlainValue  -EnvVarName "XRAY_SRV_USER" -Prompt "Enter Jira Server Username"
$srvPass = Get-SecretValue -EnvVarName "XRAY_SRV_PASS" -Prompt "Enter Jira Server Password"
$srvHeaders = New-BasicAuthHeader -User $srvUser -Secret $srvPass
$srvPass = $null
try {
    $me = Invoke-Api -Uri "$JiraServerUrl/rest/api/2/myself" -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
    Write-Log "Connected to Jira Server as: $($me.displayName)" "SUCCESS"
} catch { Write-Log "Cannot connect to Jira Server: $($_.Exception.Message)" "ERROR"; exit 1 }

function Get-Prop { param($o,[string]$n) if ($null -eq $o){return $null}; $p=$o.PSObject.Properties[$n]; if($p){return $p.Value}; return $null }
function Get-EntryUrl  { param($e) foreach ($f in 'content','fileURL','fileUrl') { $v = Get-Prop $e $f; if ($v) { return [string]$v } } ; return $null }
function Get-EntryName { param($e) foreach ($f in 'filename','fileName')         { $v = Get-Prop $e $f; if ($v) { return [string]$v } } ; return "file" }

# Set/overwrite localPath on a PSCustomObject entry (adds the property if absent).
function Set-LocalPath { param($e,[string]$Path)
    if ($e.PSObject.Properties['localPath']) { $e.localPath = $Path } else { $e | Add-Member -NotePropertyName localPath -NotePropertyValue $Path -Force }
}

$files = @(Get-ChildItem -Path $issuesRoot -Recurse -Filter *.json | Sort-Object FullName)
Write-Log "Scanning $($files.Count) exported issue records for missing binaries..."

$attempted = 0; $recovered = 0; $stillEmpty = 0; $failed = 0; $n = 0
foreach ($file in $files) {
    $n++
    try { $rec = Read-Json $file.FullName } catch { Write-Log "  Could not read $($file.Name): $($_.Exception.Message)" "WARN"; continue }
    $sk = [string]$rec.serverKey
    if (-not $sk) { continue }
    $changed = $false

    # Gather every binary entry in the record.
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($a in @(Get-Prop $rec "attachments")) { if ($a) { $entries.Add($a) } }
    $x = Get-Prop $rec "xray"
    if ($x) {
        foreach ($s in @(Get-Prop $x "manualSteps")) { foreach ($a in @(Get-Prop $s "attachments")) { if ($a) { $entries.Add($a) } } }
        foreach ($run in @(Get-Prop $x "runs")) {
            foreach ($e in @(Get-Prop $run "evidence")) { if ($e) { $entries.Add($e) } }
            foreach ($st in @(Get-Prop $run "steps")) { foreach ($e in @(Get-Prop $st "evidence")) { if ($e) { $entries.Add($e) } } }
        }
    }

    foreach ($e in $entries) {
        $lp = [string](Get-Prop $e "localPath")
        if ($lp -and (Test-Path $lp)) { continue }     # already have the file
        $url = Get-EntryUrl $e
        if (-not $url) { continue }                     # nothing to fetch
        $attempted++
        $name = Get-EntryName $e
        $id   = [string](Get-Prop $e "id")
        try {
            $bytes = Invoke-ApiBytes -Uri $url -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
            if ($null -eq $bytes -or $bytes.Length -eq 0) { $stillEmpty++; Write-Log "  [$sk] $name : empty body (0 bytes) — nothing to save" "DEBUG"; continue }
            $dir  = Join-Path $repairRoot $sk
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $dest = Join-Path $dir (Get-SafeFileName ("{0}_{1}" -f $id, $name))
            [System.IO.File]::WriteAllBytes($dest, $bytes)
            Set-LocalPath -e $e -Path $dest
            $changed = $true; $recovered++
            Write-Log "  [$sk] recovered $name ($($bytes.Length) bytes)" "SUCCESS"
        } catch {
            $failed++
            Write-Log "  [$sk] still failing $name : $($_.Exception.Message)" "WARN"
        }
    }

    if ($changed) { Save-Json -Object $rec -Path $file.FullName }
    if ($n % 200 -eq 0) { Write-Log "  ...scanned $n/$($files.Count) records (recovered=$recovered)" }
}

if ($AllowInsecureSource) { Disable-InsecureSource }

Write-Section "REPAIR SUMMARY"
Write-Host "  Records scanned : $($files.Count)" -ForegroundColor Cyan
Write-Host "  Missing found   : $attempted"      -ForegroundColor Cyan
Write-Host "  Recovered       : $recovered"      -ForegroundColor Green
Write-Host "  Empty on server : $stillEmpty"     -ForegroundColor Yellow
Write-Host "  Still failing   : $failed"         -ForegroundColor $(if($failed){'Red'}else{'Green'})
Write-Log "Repair complete. Attempted=$attempted Recovered=$recovered Empty=$stillEmpty Failed=$failed"
