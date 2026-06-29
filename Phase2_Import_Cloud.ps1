# ===================================================================
# PHASE 2 — IMPORT INTO JIRA CLOUD + XRAY CLOUD (from Phase 1 export)
# ===================================================================
#
# Rebuilds the exported Xray data in Jira Cloud + Xray Cloud using the
# correct API for each kind of data:
#
#   Jira Cloud REST v3  -> attachments, comments, links, native field promotion
#   Xray Cloud GraphQL  -> create Tests (type+steps+gherkin+generic+step
#                          attachments), create Preconditions, all associations
#   Xray Cloud REST v2  -> import test-run results (import/execution)
#
# RESUMABLE & STEPPED. Choose steps with -Steps:
#   issues        create every issue + build Server->Cloud key map
#   associations  Test Set/Plan/Execution memberships (GraphQL)
#   attachments   re-upload issue attachments
#   comments      re-create comments (author/date/visibility preserved)
#   links         re-create issue links (when both ends were migrated)
#   results       import run results onto Test Executions (incl. evidence/defects)
#   fields        (optional) promote priority/components/versions/dates/people
#                 from the export into NATIVE Cloud fields (best-effort)
#   worklogs      (optional) re-create worklogs
#   usermap       (utility) emit _user_map_template.csv to fill in
#
# Default: issues, associations, attachments, comments, links, results
#
# KEY MAP: export\<PROJECT>\_key_map.csv  (ServerKey,CloudKey,CloudId,IssueType)
# Every created issue is also stamped with a label  srvkey-<SERVERKEY>  so a
# lost-response duplicate can be detected and the run is safely resumable.
# ===================================================================

[CmdletBinding()]
param(
    [string]  $JiraCloudUrl    = "https://ankitanku090701.atlassian.net",
    [string]  $CloudProjectKey = "TEST",
    [string]  $XrayCloudBase   = "https://xray.cloud.getxray.app",   # or us/eu/au regional host
    [string]  $ServerProjectKey= "MFTBCTRKD",
    [string[]]$Steps           = @("issues","associations","attachments","comments","links","results"),
    [int]     $MaxPerType      = 0,        # 0 = all; small value for a dry run
    [int]     $CloudThrottleMs = 200,      # Jira Cloud politeness
    [int]     $XrayThrottleMs  = 1200,     # Xray Cloud ~300 req/5min => leave headroom for retries
    [bool]    $EmbedMetadataInDescription = $true,   # preserve all fields as a description block (lossless-visible)
    [bool]    $UsePreconditionGraphql     = $true,   # create Preconditions via Xray createPrecondition (richer)
    [bool]    $DedupeByServerKeyLabel     = $false,  # before creating, search for & adopt a pre-existing srvkey-<KEY> issue
                                                     # (off by default: doubles Jira calls on a fresh run; the key map +
                                                     #  non-retried creates already prevent duplicates. Turn on for a
                                                     #  re-run after a crash for belt-and-suspenders safety.)
    [string]  $SubExecFallback = "TestExecution"     # "TestExecution" | "Skip"
)

. "$PSScriptRoot\XrayMig.Common.ps1"
Initialize-XrayMig

# ===================================================================
# PATHS
# ===================================================================
$exportRoot = Join-Path $PSScriptRoot "export\$ServerProjectKey"
$issuesRoot = Join-Path $exportRoot "issues"
$keyMapFile = Join-Path $exportRoot "_key_map.csv"
$userMapFile= Join-Path $exportRoot "_user_map.csv"
$logFile    = Join-Path $exportRoot "_import.log"
$errorFile  = Join-Path $exportRoot "_import_errors.log"
$stateDir   = Join-Path $exportRoot "_state"

if (-not (Test-Path $exportRoot)) { Write-Host "Export folder not found: $exportRoot. Run Phase 1 first." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $stateDir))   { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
Set-LogFiles -LogFile $logFile -ErrorFile $errorFile

# Server display name -> Cloud Xray issue-type name (Server "Pre-Condition" -> Cloud "Precondition")
$issueTypeNameMap = @{
    "Pre-Condition"      = "Precondition"
    "Test"               = "Test"
    "Test Set"           = "Test Set"
    "Test Execution"     = "Test Execution"
    "Test Plan"          = "Test Plan"
    "Sub Test Execution" = "Sub Test Execution"
}
$createOrder = @("Pre-Condition","Test","Test Set","Test Execution","Test Plan","Sub Test Execution")

# Optional per-status override (e.g. a custom Server status -> a Cloud status that exists)
$statusOverrides = @{ }   # e.g. @{ "BLOCKED" = "FAILED" }

# ===================================================================
# HELPERS
# ===================================================================
function Get-Prop { param($Object,[string]$Name) if ($null -eq $Object){return $null}; $p=$Object.PSObject.Properties[$Name]; if($p){return $p.Value}; return $null }
function Get-TypeFolder { param([string]$ServerType) return (Join-Path $issuesRoot (Get-SafeFileName $ServerType)) }

function Get-Records {
    param([string]$ServerType)
    $folder = Get-TypeFolder $ServerType
    if (-not (Test-Path $folder)) { return @() }
    $files = @(Get-ChildItem -Path $folder -Filter "*.json" | Sort-Object Name)
    if ($MaxPerType -gt 0) { $files = @($files | Select-Object -First $MaxPerType) }
    return $files
}

function Get-DoneSet { param([string]$Name)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $f = Join-Path $stateDir "$Name.txt"
    if (Test-Path $f) { foreach ($l in [System.IO.File]::ReadAllLines($f)) { if ($l.Trim()) { [void]$set.Add($l.Trim()) } } }
    return $set
}
function Add-Done { param([string]$Name,[string]$Key,[System.Collections.Generic.HashSet[string]]$Set)
    if ($Set.Add($Key)) { Add-Content -Path (Join-Path $stateDir "$Name.txt") -Value $Key -Encoding UTF8 }
}

# ===================================================================
# AUTH — Jira Cloud + Xray Cloud
# ===================================================================
Write-Section "JIRA CLOUD LOGIN"
try {
    Confirm-BaseUrl -Url $JiraCloudUrl  -Name "JiraCloudUrl"  | Out-Null
    Confirm-BaseUrl -Url $XrayCloudBase -Name "XrayCloudBase" | Out-Null
} catch { Write-Log $_.Exception.Message "ERROR"; exit 1 }
$cloudEmail = Get-PlainValue  -EnvVarName "JIRA_CLOUD_EMAIL" -Prompt "Enter Jira Cloud Email"
$cloudToken = Get-SecretValue -EnvVarName "JIRA_CLOUD_TOKEN" -Prompt "Enter Jira Cloud API Token"
$cloudHeaders = New-BasicAuthHeader -User $cloudEmail -Secret $cloudToken
$cloudToken = $null

try {
    $me = Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/myself" -Headers $cloudHeaders -Channel "cloud-jira" -ThrottleMs $CloudThrottleMs
    $script:MyAccountId = $me.accountId
    Write-Log "Connected to Jira Cloud as: $($me.displayName) <$($me.emailAddress)> ($($me.accountId))" "SUCCESS"
} catch {
    Write-Log "Cannot connect to Jira Cloud: $($_.Exception.Message)" "ERROR"; exit 1
}

$needXray = @($Steps | Where-Object { $_ -in @("issues","associations","results") }).Count -gt 0
if ($needXray) {
    Write-Section "XRAY CLOUD LOGIN"
    $xrayClientId     = Get-PlainValue  -EnvVarName "XRAY_CLIENT_ID"     -Prompt "Enter Xray Cloud Client Id"
    $xrayClientSecret = Get-SecretValue -EnvVarName "XRAY_CLIENT_SECRET" -Prompt "Enter Xray Cloud Client Secret"
    try {
        Set-XrayAuth -BaseUrl $XrayCloudBase -ClientId $xrayClientId -ClientSecret $xrayClientSecret | Out-Null
        $xrayClientSecret = $null
        Write-Log "Authenticated to Xray Cloud (token acquired; auto-refreshes on 401 / near 24h)." "SUCCESS"
    } catch {
        Write-Log "Cannot authenticate to Xray Cloud: $($_.Exception.Message)" "ERROR"; exit 1
    }
}

# ===================================================================
# CLOUD ISSUE-TYPE IDS (resolve names -> ids for this project, paginated)
# ===================================================================
$cloudTypeId = @{}
try {
    $startAt = 0
    do {
        $itResp = Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/issue/createmeta/$CloudProjectKey/issuetypes?startAt=$startAt&maxResults=50" -Headers $cloudHeaders -Channel "cloud-jira" -ThrottleMs $CloudThrottleMs
        $itList = @()
        if ($itResp.PSObject.Properties['values'])     { $itList = @($itResp.values) }
        elseif ($itResp.PSObject.Properties['issueTypes']) { $itList = @($itResp.issueTypes) }
        elseif ($itResp -is [System.Array])            { $itList = @($itResp) }
        foreach ($it in $itList) { if ($it.name) { $cloudTypeId[$it.name] = $it.id } }
        $got = $itList.Count; $startAt += $got
        $tot = if ($itResp.PSObject.Properties['total']) { [int]$itResp.total } else { $startAt }
    } while ($got -gt 0 -and $startAt -lt $tot)
    Write-Log "Cloud issue types on '$CloudProjectKey': $(($cloudTypeId.Keys) -join ', ')"
} catch {
    Write-Log "Could not read createmeta issue types: $($_.Exception.Message). Will create by name." "WARN"
}
function Resolve-TypeRef {
    param([string]$CloudName)
    if ($cloudTypeId.ContainsKey($CloudName)) { return @{ id = $cloudTypeId[$CloudName] } }
    return @{ name = $CloudName }
}

# Guard: refuse to start the issues step if the Xray types are missing (the
# exact condition behind the past "Specify a valid issue type" 400s).
if ($Steps -contains "issues") {
    $missing = @()
    foreach ($t in @("Precondition","Test","Test Set","Test Execution","Test Plan","Sub Test Execution")) {
        if (-not $cloudTypeId.ContainsKey($t)) { $missing += $t }
    }
    if ($missing.Count) {
        Write-Log "ABORT: required Xray issue types missing on project '$CloudProjectKey': $($missing -join ', ')." "ERROR"
        Write-Log "Install/enable Xray Cloud on this project and add the types to its scheme, then re-run. (See Phase0_Preflight.ps1)" "ERROR"
        exit 1
    }
}

# ===================================================================
# KEY MAP + USER MAP
# ===================================================================
$keyMap = New-KeyMap
Import-KeyMap -KeyMap $keyMap -Path $keyMapFile
if ($keyMap.Count) { Write-Log "Loaded $($keyMap.Count) existing key mappings." }

$userMap = @{}
if (Test-Path $userMapFile) {
    Import-Csv -Path $userMapFile -Encoding UTF8 | ForEach-Object {
        if ($_.ServerUsername -and $_.CloudAccountId) { $userMap[$_.ServerUsername] = $_.CloudAccountId }
    }
    Write-Log "Loaded $($userMap.Count) user mappings."
}
function Resolve-AccountId { param([string]$ServerUser) if ($ServerUser -and $userMap.ContainsKey($ServerUser)) { return $userMap[$ServerUser] }; return $null }

# ===================================================================
# DESCRIPTION / METADATA
# ===================================================================
function Format-FieldValue {
    param($v)
    if ($null -eq $v) { return "" }
    if ($v -is [string])  { $s = $v }
    elseif ($v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double]) { $s = [string]$v }
    elseif ($v -is [System.Array]) { $s = ((@($v) | ForEach-Object { Format-FieldValue $_ }) -join ', ') }
    elseif ($v.PSObject -and $v.PSObject.Properties['value']) { $s = [string]$v.value }
    elseif ($v.PSObject -and $v.PSObject.Properties['name'])  { $s = [string]$v.name }
    else { try { $s = ($v | ConvertTo-Json -Depth 5 -Compress) } catch { $s = [string]$v } }
    if ($s.Length -gt 800) { $s = $s.Substring(0,800) + "..." }
    return $s
}

function Build-MetadataBlock {
    param($Rec)
    $j = $Rec.jira
    $lines = @("---- Migrated from $($Rec.serverKey) ($($Rec.issueType)) ----")
    $st = Get-Prop $j "status";      if ($st) { $lines += "Status: $st" }
    $rs = Get-Prop $j "resolution";  if ($rs) { $lines += "Resolution: $rs" }
    $pr = Get-Prop $j "priority";    if ($pr) { $lines += "Priority: $pr" }
    $comp = @(Get-Prop $j "components")      -join ', '; if ($comp) { $lines += "Components: $comp" }
    $fv   = @(Get-Prop $j "fixVersions")     -join ', '; if ($fv)   { $lines += "Fix Versions: $fv" }
    $av   = @(Get-Prop $j "affectsVersions") -join ', '; if ($av)   { $lines += "Affects Versions: $av" }
    $env  = Get-Prop $j "environment"; if ($env) { $lines += "Environment: $env" }
    $due  = Get-Prop $j "duedate";     if ($due) { $lines += "Due: $due" }
    $rep = Get-Prop $j "reporter"; if ($rep) { $rd = Get-Prop $rep "displayName"; if ($rd) { $lines += "Reporter: $rd" } }
    $asg = Get-Prop $j "assignee"; if ($asg) { $ad = Get-Prop $asg "displayName"; if ($ad) { $lines += "Assignee: $ad" } }
    $cr = Get-Prop $j "created"; if ($cr) { $lines += "Created: $cr" }
    $up = Get-Prop $j "updated"; if ($up) { $lines += "Updated: $up" }
    $cfs = Get-Prop $j "customFields"
    if ($cfs) {
        foreach ($p in $cfs.PSObject.Properties) {
            $cf = $p.Value
            $name = [string](Get-Prop $cf "name"); if (-not $name) { $name = $p.Name }
            $val  = Format-FieldValue (Get-Prop $cf "value")
            if ($val) { $lines += ("{0}: {1}" -f $name, $val) }
        }
    }
    return ($lines -join "`n")
}

# Compose the description text + ADF, returning any overflow to post as a comment.
function Build-Description {
    param($Rec, [string]$ExtraDescription)
    $j = $Rec.jira
    $descText = ""
    $dh = Get-Prop $j "descriptionHtml"; $dt = Get-Prop $j "description"
    if ($dh) { $descText = ConvertFrom-HtmlToText ([string]$dh) }
    elseif ($dt) { $descText = [string]$dt }
    $tail = @()
    if ($ExtraDescription) { $tail += $ExtraDescription }
    if ($EmbedMetadataInDescription) { $tail += (Build-MetadataBlock -Rec $Rec) }
    if ($tail.Count) { $descText = (@($descText) + $tail | Where-Object { $_ }) -join "`n`n" }
    return (ConvertTo-AdfEx -Text $descText)
}

function Build-StandardFields {
    param($Rec, [string]$CloudTypeName, [string]$ExtraDescription)
    $j = $Rec.jira
    $summary = [string](Get-Prop $j "summary")
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = "(no summary) $($Rec.serverKey)" }
    if ($summary.Length -gt 255) { $summary = $summary.Substring(0,255) }

    $descRes = Build-Description -Rec $Rec -ExtraDescription $ExtraDescription

    $fields = @{
        project   = @{ key = $CloudProjectKey }
        summary   = $summary
        issuetype = (Resolve-TypeRef $CloudTypeName)
    }
    if ($descRes.Adf) { $fields.description = $descRes.Adf }

    # Stamp the ServerKey as a label so the issue is self-identifying / dedupe-able.
    $labels = @()
    foreach ($l in @(Get-Prop $j "labels")) { $sl = Get-SafeLabel $l; if ($sl) { $labels += $sl } }
    $labels += ("srvkey-" + ($Rec.serverKey -replace '\s','_'))
    $fields.labels = @($labels | Select-Object -Unique)

    return @{ Fields = $fields; Overflow = $descRes.Overflow }
}

# ===================================================================
# JIRA CLOUD: create one issue (returns @{ key; id })
#   Create POSTs are NOT idempotent — Invoke-Api is called with
#   -Idempotent:$false so a 5xx is never blindly retried into a duplicate.
# ===================================================================
function New-CloudIssue {
    param([hashtable]$Fields)
    $resp = Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/issue" -Method Post -Headers $cloudHeaders `
                -Body (@{ fields = $Fields } | ConvertTo-Json -Depth 100) -Channel "cloud-jira" -ThrottleMs $CloudThrottleMs `
                -Idempotent:$false
    return [pscustomobject]@{ key = $resp.key; id = $resp.id }
}

# Adopt a pre-existing issue carrying srvkey-<KEY> (covers the lost-response edge case).
function Find-ExistingByServerKey {
    param([string]$ServerKey)
    if (-not $DedupeByServerKeyLabel) { return $null }
    try {
        $label = "srvkey-" + ($ServerKey -replace '\s','_')
        $jql = "project = `"$CloudProjectKey`" AND labels = `"$label`""
        $enc = [uri]::EscapeDataString($jql)
        # /rest/api/3/search (GET) was deprecated/removed; use /search/jql.
        $r = Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/search/jql?jql=$enc&maxResults=1&fields=summary" -Headers $cloudHeaders -Channel "cloud-jira" -ThrottleMs $CloudThrottleMs
        $hits = @($r.issues)
        if ($hits.Count -gt 0) { return [pscustomobject]@{ key = $hits[0].key; id = $hits[0].id } }
    } catch {}
    return $null
}

# Post the description overflow (text beyond the ADF size limit) as a comment.
function Add-OverflowComment {
    param([string]$CloudKey, [string]$Overflow)
    if (-not $Overflow) { return }
    $adf = ConvertTo-Adf -Text ("[Migration: description continued]`n`n" + $Overflow)
    if ($adf) {
        try { Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/issue/$CloudKey/comment" -Method Post -Headers $cloudHeaders -Body (@{ body = $adf } | ConvertTo-Json -Depth 100) -Channel "cloud-jira" -ThrottleMs $CloudThrottleMs | Out-Null } catch {}
    }
}

# ===================================================================
# XRAY CLOUD: GraphQL mutations
# ===================================================================
$createTestMutation = @'
mutation CreateTest($testType: UpdateTestTypeInput, $steps: [CreateStepInput], $gherkin: String, $unstructured: String, $preconditionIssueIds: [String], $folderPath: String, $jira: JSON!) {
  createTest(testType: $testType, steps: $steps, gherkin: $gherkin, unstructured: $unstructured, preconditionIssueIds: $preconditionIssueIds, folderPath: $folderPath, jira: $jira) {
    test { issueId jira(fields: ["key"]) }
    warnings
  }
}
'@

$createPreconditionMutation = @'
mutation CreatePrecondition($preconditionType: UpdatePreconditionTypeInput, $definition: String, $jira: JSON!) {
  createPrecondition(preconditionType: $preconditionType, definition: $definition, jira: $jira) {
    precondition { issueId jira(fields: ["key"]) }
    warnings
  }
}
'@

function Get-GherkinFromZip {
    param([string]$ZipPath)
    if (-not $ZipPath -or -not (Test-Path $ZipPath)) { return "" }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -match '\.feature$' } | Select-Object -First 1
            if ($entry) { $sr = New-Object System.IO.StreamReader($entry.Open()); $txt = $sr.ReadToEnd(); $sr.Close(); return $txt }
        } finally { $zip.Dispose() }
    } catch {}
    return ""
}

function New-AttachmentInput {
    param([string]$LocalPath, [string]$FileName)
    if (-not $LocalPath -or -not (Test-Path $LocalPath)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($LocalPath)
        $name  = if ($FileName) { $FileName } else { Split-Path $LocalPath -Leaf }
        return @{ filename = $name; mimeType = (Get-MimeType $name); data = [Convert]::ToBase64String($bytes) }
    } catch { return $null }
}

function New-CloudTest {
    param($Rec)
    $x = $Rec.xray
    $testType = [string](Get-Prop $x "testType")
    $gherkin  = [string](Get-Prop $x "gherkin")
    $unstruct = [string](Get-Prop $x "unstructured")
    $steps    = @(Get-Prop $x "manualSteps")

    $kind = switch -Regex ($testType) {
        'cucumber|gherkin|bdd|scenario'            { 'Cucumber'; break }
        'generic|automat|unstructured|definition'  { 'Generic';  break }
        'manual|steps|^$'                          { 'Manual';   break }
        default { if ($gherkin) { 'Cucumber' } elseif ($unstruct) { 'Generic' } elseif ($steps.Count) { 'Manual' } else { 'Manual' } }
    }
    if ([string]::IsNullOrWhiteSpace($testType)) {
        if ($gherkin) { $kind = "Cucumber" } elseif ($unstruct) { $kind = "Generic" } else { $kind = "Manual" }
    }
    if ($kind -eq "Cucumber" -and -not $gherkin) { $gherkin = Get-GherkinFromZip -ZipPath (Get-Prop $x "featureFile") }

    # Warn loudly (do not silently create an empty test) when a non-manual test
    # has no definition content.
    if ($kind -eq "Cucumber" -and -not $gherkin)  { Write-Log "    [$($Rec.serverKey)] Cucumber test has NO gherkin content — creating anyway, review." "WARN" }
    if ($kind -eq "Generic"  -and -not $unstruct) { Write-Log "    [$($Rec.serverKey)] Generic test has NO definition content — creating anyway, review." "WARN" }

    $sf = Build-StandardFields -Rec $Rec -CloudTypeName "Test"
    # createTest builds its own Test issue type — pass only project/summary/description/labels.
    $jira = @{ fields = @{ project = @{ key = $CloudProjectKey }; summary = $sf.Fields.summary; labels = $sf.Fields.labels } }
    if ($sf.Fields.ContainsKey("description")) { $jira.fields.description = $sf.Fields.description }

    $vars = @{ testType = @{ name = $kind }; jira = $jira }

    if ($kind -eq "Manual" -and $steps.Count) {
        $vars.steps = @( $steps | ForEach-Object {
            $stepObj = @{ action = [string]$_.action; data = [string]$_.data; result = [string]$_.result }
            # Bind per-step DEFINITION attachments to the step (not the issue).
            $atts = @()
            foreach ($a in @(Get-Prop $_ "attachments")) {
                $ai = New-AttachmentInput -LocalPath ([string](Get-Prop $a "localPath")) -FileName ([string](Get-Prop $a "fileName"))
                if ($ai) { $atts += $ai }
            }
            if ($atts.Count) { $stepObj.attachments = $atts }
            $stepObj
        })
    }
    if ($kind -eq "Cucumber" -and $gherkin)  { $vars.gherkin = $gherkin }
    if ($kind -eq "Generic"  -and $unstruct) { $vars.unstructured = $unstruct }

    $preIds = @()
    foreach ($p in @(Get-Prop $x "preconditions")) {
        $pk = [string](Get-Prop $p "key")
        if ($pk -and $keyMap.ContainsKey($pk)) { $preIds += [string]$keyMap[$pk].CloudId }
    }
    if ($preIds.Count) { $vars.preconditionIssueIds = $preIds }

    $repo = [string](Get-Prop $x "repositoryPath")
    if ($repo) { $vars.folderPath = $repo }

    $data = Invoke-Graphql -BaseUrl $XrayCloudBase -Query $createTestMutation -Variables $vars -ThrottleMs $XrayThrottleMs
    $test = $data.createTest.test
    $warns = @($data.createTest.warnings)
    if ($warns.Count) { Write-Log "    createTest warnings ($($Rec.serverKey)): $($warns -join '; ')" "WARN" }
    $res = [pscustomobject]@{ key = ($test.jira.key); id = [string]$test.issueId }
    if ($sf.Overflow) { Add-OverflowComment -CloudKey $res.key -Overflow $sf.Overflow }
    return $res
}

function New-CloudPrecondition {
    param($Rec)
    $x = $Rec.xray
    $ct = [string](Get-Prop $x "conditionType"); if (-not $ct) { $ct = "Generic" }
    $kind = switch -Regex ($ct) { 'cucumber|gherkin' { 'Cucumber'; break } 'manual' { 'Manual'; break } default { 'Generic' } }
    $cond = [string](Get-Prop $x "condition")

    $sf = Build-StandardFields -Rec $Rec -CloudTypeName "Precondition"
    $jira = @{ fields = @{ project = @{ key = $CloudProjectKey }; summary = $sf.Fields.summary; labels = $sf.Fields.labels } }
    if ($sf.Fields.ContainsKey("description")) { $jira.fields.description = $sf.Fields.description }

    $vars = @{ preconditionType = @{ name = $kind }; jira = $jira }
    if ($cond) { $vars.definition = $cond }

    $data = Invoke-Graphql -BaseUrl $XrayCloudBase -Query $createPreconditionMutation -Variables $vars -ThrottleMs $XrayThrottleMs
    $pre = $data.createPrecondition.precondition
    $warns = @($data.createPrecondition.warnings)
    if ($warns.Count) { Write-Log "    createPrecondition warnings ($($Rec.serverKey)): $($warns -join '; ')" "WARN" }
    $res = [pscustomobject]@{ key = ($pre.jira.key); id = [string]$pre.issueId }
    if ($sf.Overflow) { Add-OverflowComment -CloudKey $res.key -Overflow $sf.Overflow }
    return $res
}

# ===================================================================
# STEP: issues
# ===================================================================
function Step-Issues {
    Write-Section "STEP: CREATE ISSUES"
    foreach ($serverType in $createOrder) {
        $cloudType = $issueTypeNameMap[$serverType]
        $files = @(Get-Records $serverType)
        if (-not $files.Count) { Write-Log "No exported $serverType issues." "DEBUG"; continue }
        Write-Log "Creating $($files.Count) '$serverType' -> '$cloudType'"
        $i = 0
        foreach ($file in $files) {
            $i++
            $rec = Read-Json $file.FullName
            $sk  = [string]$rec.serverKey
            if ($keyMap.ContainsKey($sk)) { Write-Log "  [$sk] already created -> $($keyMap[$sk].CloudKey). Skip." "DEBUG"; continue }

            # Lost-response safety: adopt an existing srvkey-stamped issue if present.
            $existing = Find-ExistingByServerKey -ServerKey $sk
            if ($existing) {
                $entry = [pscustomobject]@{ CloudKey = $existing.key; CloudId = $existing.id; IssueType = $serverType }
                $keyMap[$sk] = $entry; Add-KeyMapRow -Path $keyMapFile -ServerKey $sk -Entry $entry
                Write-Log "  [$sk] adopted existing $($existing.key) (srvkey label)." "WARN"; continue
            }

            try {
                if ($serverType -eq "Test") {
                    $res = New-CloudTest -Rec $rec
                }
                elseif ($serverType -eq "Pre-Condition") {
                    if ($UsePreconditionGraphql) {
                        $res = New-CloudPrecondition -Rec $rec
                    } else {
                        $extra = $null
                        if ($rec.xray) {
                            $ct = [string](Get-Prop $rec.xray "conditionType"); $cd = [string](Get-Prop $rec.xray "condition")
                            if ($ct -or $cd) { $extra = "---- Xray Precondition ----`nType: $ct`n$cd" }
                        }
                        $sf = Build-StandardFields -Rec $rec -CloudTypeName $cloudType -ExtraDescription $extra
                        $res = New-CloudIssue -Fields $sf.Fields
                        if ($sf.Overflow) { Add-OverflowComment -CloudKey $res.key -Overflow $sf.Overflow }
                    }
                }
                elseif ($serverType -eq "Sub Test Execution") {
                    $parentSk = [string]$rec.jira.parentKey
                    if ($parentSk -and $keyMap.ContainsKey($parentSk)) {
                        $sf = Build-StandardFields -Rec $rec -CloudTypeName $cloudType
                        $sf.Fields.parent = @{ key = $keyMap[$parentSk].CloudKey }
                        $res = New-CloudIssue -Fields $sf.Fields
                        if ($sf.Overflow) { Add-OverflowComment -CloudKey $res.key -Overflow $sf.Overflow }
                    } elseif ($SubExecFallback -eq "TestExecution") {
                        Write-Log "  [$sk] parent '$parentSk' not migrated — creating as standalone Test Execution." "WARN"
                        $sf = Build-StandardFields -Rec $rec -CloudTypeName "Test Execution"
                        $sf.Fields.labels = @($sf.Fields.labels + "migrated-sub-test-execution" | Select-Object -Unique)
                        $res = New-CloudIssue -Fields $sf.Fields
                        if ($sf.Overflow) { Add-OverflowComment -CloudKey $res.key -Overflow $sf.Overflow }
                    } else {
                        Write-Log "  [$sk] parent '$parentSk' not migrated — skipped (SubExecFallback=Skip)." "WARN"; continue
                    }
                }
                else {
                    $sf = Build-StandardFields -Rec $rec -CloudTypeName $cloudType
                    $res = New-CloudIssue -Fields $sf.Fields
                    if ($sf.Overflow) { Add-OverflowComment -CloudKey $res.key -Overflow $sf.Overflow }
                }

                $entry = [pscustomobject]@{ CloudKey = $res.key; CloudId = $res.id; IssueType = $serverType }
                $keyMap[$sk] = $entry
                Add-KeyMapRow -Path $keyMapFile -ServerKey $sk -Entry $entry   # persist immediately (crash-safe)
                Write-Log "  [$sk] -> [$($res.key)] ($i/$($files.Count))" "SUCCESS"
            } catch {
                Write-Log "  [$sk] FAILED: $($_.Exception.Message)" "ERROR"
            }
        }
        Save-KeyMap -KeyMap $keyMap -Path $keyMapFile
    }
    Save-KeyMap -KeyMap $keyMap -Path $keyMapFile
}

# ===================================================================
# STEP: associations  (GraphQL)
# ===================================================================
$addToSet      = 'mutation($id:String!,$tests:[String]!){ addTestsToTestSet(issueId:$id,testIssueIds:$tests){ addedTests warning } }'
$addToPlan     = 'mutation($id:String!,$tests:[String]!){ addTestsToTestPlan(issueId:$id,testIssueIds:$tests){ addedTests warning } }'
$addExecToPlan = 'mutation($id:String!,$execs:[String]!){ addTestExecutionsToTestPlan(issueId:$id,testExecIssueIds:$execs){ addedTestExecutions warning } }'
$addToExec     = 'mutation($id:String!,$tests:[String]!){ addTestsToTestExecution(issueId:$id,testIssueIds:$tests){ addedTests warning } }'

function Resolve-CloudIds { param($MemberList)
    $ids = @()
    foreach ($m in @($MemberList)) {
        $k = [string](Get-Prop $m "key")
        if ($k -and $keyMap.ContainsKey($k)) { $ids += [string]$keyMap[$k].CloudId }
    }
    return ,$ids
}
function Invoke-AddBatched {
    param([string]$Mutation,[string]$ContainerId,[string[]]$Ids,[string]$VarName)
    $Ids = @($Ids)
    if (-not $Ids.Count) { return }
    for ($i = 0; $i -lt $Ids.Count; $i += 100) {
        $batch = @($Ids[$i..([math]::Min($i+99,$Ids.Count-1))])
        $vars = @{ id = $ContainerId }; $vars[$VarName] = $batch
        Invoke-Graphql -BaseUrl $XrayCloudBase -Query $Mutation -Variables $vars -ThrottleMs $XrayThrottleMs | Out-Null
    }
}

function Step-Associations {
    Write-Section "STEP: ASSOCIATIONS"
    $done = Get-DoneSet "associations"

    foreach ($pair in @(
        @{ Type="Test Set";       Mut=$addToSet;  Var="tests"; Members="tests" },
        @{ Type="Test Execution"; Mut=$addToExec; Var="tests"; Members="tests" }
    )) {
        foreach ($file in (Get-Records $pair.Type)) {
            $rec = Read-Json $file.FullName; $sk = [string]$rec.serverKey
            if ($done.Contains($sk) -or -not $keyMap.ContainsKey($sk)) { continue }
            $cid = [string]$keyMap[$sk].CloudId
            $ids = Resolve-CloudIds (Get-Prop $rec.xray $pair.Members)
            try {
                Invoke-AddBatched -Mutation $pair.Mut -ContainerId $cid -Ids $ids -VarName $pair.Var
                Write-Log "  [$sk] $($pair.Type): linked $(@($ids).Count) tests" "SUCCESS"
                Add-Done "associations" $sk $done
            } catch { Write-Log "  [$sk] $($pair.Type) association failed: $($_.Exception.Message)" "ERROR" }
        }
    }

    foreach ($file in (Get-Records "Test Plan")) {
        $rec = Read-Json $file.FullName; $sk = [string]$rec.serverKey
        if ($done.Contains($sk) -or -not $keyMap.ContainsKey($sk)) { continue }
        $cid = [string]$keyMap[$sk].CloudId
        try {
            $testIds = Resolve-CloudIds (Get-Prop $rec.xray "tests")
            $execIds = Resolve-CloudIds (Get-Prop $rec.xray "testExecutions")
            Invoke-AddBatched -Mutation $addToPlan     -ContainerId $cid -Ids $testIds -VarName "tests"
            Invoke-AddBatched -Mutation $addExecToPlan -ContainerId $cid -Ids $execIds -VarName "execs"
            Write-Log "  [$sk] Test Plan: $(@($testIds).Count) tests, $(@($execIds).Count) executions" "SUCCESS"
            Add-Done "associations" $sk $done
        } catch { Write-Log "  [$sk] Test Plan association failed: $($_.Exception.Message)" "ERROR" }
    }
}

# ===================================================================
# STEP: attachments  (per-item resumability — only mark done if no errors)
# ===================================================================
function Step-Attachments {
    Write-Section "STEP: ATTACHMENTS"
    $done = Get-DoneSet "attachments"
    foreach ($serverType in $createOrder) {
        foreach ($file in (Get-Records $serverType)) {
            $rec = Read-Json $file.FullName; $sk = [string]$rec.serverKey
            if ($done.Contains($sk) -or -not $keyMap.ContainsKey($sk)) { continue }
            $cloudKey = $keyMap[$sk].CloudKey

            $atts = @($rec.attachments | Where-Object { $_.localPath -and (Test-Path $_.localPath) } |
                        ForEach-Object { [pscustomobject]@{ path = $_.localPath; name = $_.filename } })

            $n = 0; $err = 0
            foreach ($a in $atts) {
                try {
                    Invoke-MultipartUpload -Uri "$JiraCloudUrl/rest/api/3/issue/$cloudKey/attachments" -Headers $cloudHeaders `
                        -FilePath $a.path -FileName $a.name -Channel "cloud-jira" -ThrottleMs $CloudThrottleMs | Out-Null
                    $n++
                } catch { $err++; Write-Log "  [$sk] attachment '$($a.name)' failed: $($_.Exception.Message)" "ERROR" }
            }
            if ($atts.Count) { Write-Log "  [$sk] -> $cloudKey : $n/$($atts.Count) attachments" "SUCCESS" }
            if ($err -eq 0) { Add-Done "attachments" $sk $done }   # retry the issue next run if any item failed
        }
    }
}

# ===================================================================
# STEP: comments  (preserve author/date/visibility; rendered HTML -> ADF)
# ===================================================================
function Step-Comments {
    Write-Section "STEP: COMMENTS"
    $done = Get-DoneSet "comments"
    foreach ($serverType in $createOrder) {
        foreach ($file in (Get-Records $serverType)) {
            $rec = Read-Json $file.FullName; $sk = [string]$rec.serverKey
            if ($done.Contains($sk) -or -not $keyMap.ContainsKey($sk)) { continue }
            $cloudKey = $keyMap[$sk].CloudKey
            $comments = @($rec.comments)
            $n = 0; $err = 0
            foreach ($c in $comments) {
                $who = [string](Get-Prop $c "author"); $when = [string](Get-Prop $c "created")
                $html = Get-Prop $c "bodyHtml"
                if ($html) { $bodyText = ConvertFrom-HtmlToText ([string]$html) } else { $bodyText = [string](Get-Prop $c "body") }
                $prefix = "[Migrated comment — $who, $when]"
                $adf = ConvertTo-Adf -Text ($prefix + "`n`n" + $bodyText)
                if (-not $adf) { continue }
                $payload = @{ body = $adf }
                # Preserve restricted-comment visibility so it is not made public.
                $vis = Get-Prop $c "visibility"
                if ($vis) {
                    $vt = [string](Get-Prop $vis "type"); $vv = [string](Get-Prop $vis "value")
                    if ($vt -and $vv) { $payload.visibility = @{ type = $vt; value = $vv } }
                }
                try {
                    Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/issue/$cloudKey/comment" -Method Post -Headers $cloudHeaders `
                        -Body ($payload | ConvertTo-Json -Depth 100) -Channel "cloud-jira" -ThrottleMs $CloudThrottleMs -Idempotent:$false | Out-Null
                    $n++
                } catch { $err++; Write-Log "  [$sk] comment failed: $($_.Exception.Message)" "ERROR" }
            }
            if ($comments.Count) { Write-Log "  [$sk] -> $cloudKey : $n/$($comments.Count) comments" "SUCCESS" }
            if ($err -eq 0) { Add-Done "comments" $sk $done }
        }
    }
}

# ===================================================================
# STEP: links  (only when both ends migrated; outward only to dedupe)
# ===================================================================
function Step-Links {
    Write-Section "STEP: ISSUE LINKS"
    $done = Get-DoneSet "links"
    $cloudLinkTypes = New-Object 'System.Collections.Generic.HashSet[string]'
    try {
        $lt = Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/issueLinkType" -Headers $cloudHeaders -Channel "cloud-jira" -ThrottleMs $CloudThrottleMs
        foreach ($t in $lt.issueLinkTypes) { [void]$cloudLinkTypes.Add($t.name) }
    } catch { Write-Log "Could not list cloud link types: $($_.Exception.Message)" "WARN" }

    foreach ($serverType in $createOrder) {
        foreach ($file in (Get-Records $serverType)) {
            $rec = Read-Json $file.FullName; $sk = [string]$rec.serverKey
            if ($done.Contains($sk) -or -not $keyMap.ContainsKey($sk)) { continue }
            $fromKey = $keyMap[$sk].CloudKey
            $n = 0; $err = 0
            foreach ($l in @($rec.issueLinks)) {
                if ((Get-Prop $l "direction") -ne "outward") { continue }
                $linkedSk = [string](Get-Prop $l "linkedKey")
                $typeName = [string](Get-Prop $l "typeName")
                if (-not $keyMap.ContainsKey($linkedSk)) { continue }
                if ($cloudLinkTypes.Count -and -not $cloudLinkTypes.Contains($typeName)) { Write-Log "  [$sk] link type '$typeName' missing on cloud — skipped" "WARN"; continue }
                $toKey = $keyMap[$linkedSk].CloudKey
                $body = @{ type = @{ name = $typeName }; outwardIssue = @{ key = $fromKey }; inwardIssue = @{ key = $toKey } }
                try {
                    Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/issueLink" -Method Post -Headers $cloudHeaders `
                        -Body ($body | ConvertTo-Json -Depth 100) -Channel "cloud-jira" -ThrottleMs $CloudThrottleMs -Idempotent:$false | Out-Null
                    $n++
                } catch { $err++; Write-Log "  [$sk] link -> $linkedSk ($typeName) failed: $($_.Exception.Message)" "ERROR" }
            }
            if ($n) { Write-Log "  [$sk] created $n links" "SUCCESS" }
            if ($err -eq 0) { Add-Done "links" $sk $done }
        }
    }
}

# ===================================================================
# STEP: results  (Xray Cloud import/execution)
# ===================================================================
function Get-EvidenceObject { param([string]$LocalPath)
    if (-not $LocalPath -or -not (Test-Path $LocalPath)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($LocalPath)
        $name  = Split-Path $LocalPath -Leaf
        return @{ data = [Convert]::ToBase64String($bytes); filename = $name; contentType = (Get-MimeType $name) }
    } catch { return $null }
}

# Build the tests[] entry for one run.
function Build-RunPayload {
    param($run)
    $stk = [string](Get-Prop $run "testKey")
    if (-not $keyMap.ContainsKey($stk)) { return $null }
    $t = @{ testKey = $keyMap[$stk].CloudKey; status = (Convert-XrayStatus ([string](Get-Prop $run "status")) $statusOverrides) }

    $cmt = [string](Get-Prop $run "comment"); $extraCmt = @()
    $st  = [string](Get-Prop $run "startedOn");  if ($st) { $t.start  = $st }
    $fin = [string](Get-Prop $run "finishedOn"); if ($fin){ $t.finish = $fin }

    $by  = [string](Get-Prop $run "executedBy"); $acc = Resolve-AccountId $by
    if ($acc) { $t.executedBy = $acc } elseif ($by) { $extraCmt += "[Originally executed by: $by]" }

    $asg = [string](Get-Prop $run "assignee"); $accA = Resolve-AccountId $asg
    if ($accA) { $t.assignee = $accA } elseif ($asg) { $extraCmt += "[Originally assigned to: $asg]" }

    # Defects: send original keys even if not migrated (they exist on the same site
    # when in another project) so the linkage is never silently dropped.
    $defs = @()
    foreach ($d in @(Get-Prop $run "defects")) {
        if (-not $d) { continue }
        if ($keyMap.ContainsKey([string]$d)) { $defs += $keyMap[[string]$d].CloudKey } else { $defs += [string]$d }
    }
    if ($defs.Count) { $t.defects = @($defs | Select-Object -Unique) }

    $ev = @()
    foreach ($e in @(Get-Prop $run "evidence")) { $o = Get-EvidenceObject ([string](Get-Prop $e "localPath")); if ($o) { $ev += $o } }
    if ($ev.Count) { $t.evidence = $ev }

    $steps = @()
    foreach ($s in @(Get-Prop $run "steps")) {
        $stepObj = @{ status = (Convert-XrayStatus ([string](Get-Prop $s "status")) $statusOverrides) }
        $sc = [string](Get-Prop $s "comment");      if ($sc) { $stepObj.comment = $sc }
        $ar = [string](Get-Prop $s "actualResult"); if ($ar) { $stepObj.actualResult = $ar }
        $sev = @()
        foreach ($e in @(Get-Prop $s "evidence")) { $o = Get-EvidenceObject ([string](Get-Prop $e "localPath")); if ($o) { $sev += $o } }
        if ($sev.Count) { $stepObj.evidence = $sev }
        $steps += $stepObj
    }
    if ($steps.Count) { $t.steps = $steps }

    if ($extraCmt.Count) { $cmt = (@($cmt) + $extraCmt | Where-Object { $_ }) -join "`n" }
    if ($cmt) { $t.comment = $cmt }

    # Carry data-driven iteration/example results raw so they are preserved.
    $iter = Get-Prop $run "iterations"; if ($iter) { $t.iterations = $iter }
    $exmp = Get-Prop $run "examples";   if ($exmp) { $t.examples   = $exmp }

    return $t
}

function Import-Execution {
    param([string]$CloudExecKey, $Tests, $TestEnvironments)
    $payload = @{ testExecutionKey = $CloudExecKey; tests = @($Tests) }
    if ($TestEnvironments -and @($TestEnvironments).Count) { $payload.info = @{ testEnvironments = @($TestEnvironments) } }
    Invoke-XrayRest -Uri "$XrayCloudBase/api/v2/import/execution" -Method Post -Body $payload -ThrottleMs $XrayThrottleMs | Out-Null
}

function Step-Results {
    Write-Section "STEP: IMPORT RESULTS"
    $done = Get-DoneSet "results"
    foreach ($serverType in @("Test Execution","Sub Test Execution")) {
        foreach ($file in (Get-Records $serverType)) {
            $rec = Read-Json $file.FullName; $sk = [string]$rec.serverKey
            if ($done.Contains($sk) -or -not $keyMap.ContainsKey($sk)) { continue }
            $cloudExecKey = $keyMap[$sk].CloudKey
            $runs = @(Get-Prop $rec.xray "runs")
            if (-not $runs.Count) { Add-Done "results" $sk $done; continue }
            $testEnvs = @(Get-Prop $rec.xray "testEnvironments")

            $tests = @()
            foreach ($run in $runs) {
                $t = Build-RunPayload -run $run
                if ($t) { $tests += $t } else { Write-Log "  [$sk] run test '$([string](Get-Prop $run "testKey"))' not migrated — skipped" "WARN" }
            }
            if (-not $tests.Count) { Add-Done "results" $sk $done; continue }

            try {
                Import-Execution -CloudExecKey $cloudExecKey -Tests $tests -TestEnvironments $testEnvs
                Write-Log "  [$sk] -> $cloudExecKey : imported $($tests.Count) test runs" "SUCCESS"
                Add-Done "results" $sk $done
            } catch {
                # Per-run fallback: one bad status/test must not drop the whole execution.
                Write-Log "  [$sk] batch import failed ($($_.Exception.Message)). Retrying per-run..." "WARN"
                $ok = 0; $bad = 0
                foreach ($t in $tests) {
                    try { Import-Execution -CloudExecKey $cloudExecKey -Tests @($t) -TestEnvironments $testEnvs; $ok++ }
                    catch { $bad++; Write-Log "    [$sk] run '$($t.testKey)' failed: $($_.Exception.Message)" "ERROR" }
                }
                Write-Log "  [$sk] -> $cloudExecKey : per-run import ok=$ok failed=$bad" $(if($bad){"WARN"}else{"SUCCESS"})
                if ($bad -eq 0) { Add-Done "results" $sk $done }
            }
        }
    }
}

# ===================================================================
# STEP: fields  (OPTIONAL — promote native Cloud fields, best-effort)
#   Each field is set independently; a rejected field is logged and skipped
#   so it never fails the whole issue. Custom fields stay in the description
#   metadata block (mapping them to Cloud custom-field ids is site-specific).
# ===================================================================
function Set-CloudField {
    param([string]$CloudKey, [hashtable]$FieldFragment, [string]$Label)
    try {
        Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/issue/$CloudKey" -Method Put -Headers $cloudHeaders `
            -Body (@{ fields = $FieldFragment } | ConvertTo-Json -Depth 100) -Channel "cloud-jira" -ThrottleMs $CloudThrottleMs -Idempotent:$false | Out-Null
        return $true
    } catch { Write-Log "    [$CloudKey] could not set $Label : $($_.Exception.Message)" "WARN"; return $false }
}

function Step-Fields {
    Write-Section "STEP: NATIVE FIELD PROMOTION (best-effort)"
    $done = Get-DoneSet "fields"
    foreach ($serverType in $createOrder) {
        foreach ($file in (Get-Records $serverType)) {
            $rec = Read-Json $file.FullName; $sk = [string]$rec.serverKey
            if ($done.Contains($sk) -or -not $keyMap.ContainsKey($sk)) { continue }
            $cloudKey = $keyMap[$sk].CloudKey; $j = $rec.jira

            $pr = [string](Get-Prop $j "priority"); if ($pr) { Set-CloudField $cloudKey @{ priority = @{ name = $pr } } "priority" | Out-Null }
            $due = [string](Get-Prop $j "duedate"); if ($due) { Set-CloudField $cloudKey @{ duedate = $due } "duedate" | Out-Null }

            $comp = @(Get-Prop $j "components") | Where-Object { $_ }
            if ($comp.Count) { Set-CloudField $cloudKey @{ components = @($comp | ForEach-Object { @{ name = $_ } }) } "components" | Out-Null }
            $fv = @(Get-Prop $j "fixVersions") | Where-Object { $_ }
            if ($fv.Count) { Set-CloudField $cloudKey @{ fixVersions = @($fv | ForEach-Object { @{ name = $_ } }) } "fixVersions" | Out-Null }
            $av = @(Get-Prop $j "affectsVersions") | Where-Object { $_ }
            if ($av.Count) { Set-CloudField $cloudKey @{ versions = @($av | ForEach-Object { @{ name = $_ } }) } "affectsVersions" | Out-Null }

            $rep = [string](Get-Prop (Get-Prop $j "reporter") "name"); $accR = Resolve-AccountId $rep
            if ($accR) { Set-CloudField $cloudKey @{ reporter = @{ id = $accR } } "reporter" | Out-Null }
            $asg = [string](Get-Prop (Get-Prop $j "assignee") "name"); $accA = Resolve-AccountId $asg
            if ($accA) { Set-CloudField $cloudKey @{ assignee = @{ id = $accA } } "assignee" | Out-Null }

            Add-Done "fields" $sk $done
            Write-Log "  [$sk] -> $cloudKey native fields promoted (best-effort)" "SUCCESS"
        }
    }
}

# ===================================================================
# STEP: worklogs (OPTIONAL)
# ===================================================================
function Step-Worklogs {
    Write-Section "STEP: WORKLOGS"
    $done = Get-DoneSet "worklogs"
    foreach ($serverType in $createOrder) {
        foreach ($file in (Get-Records $serverType)) {
            $rec = Read-Json $file.FullName; $sk = [string]$rec.serverKey
            if ($done.Contains($sk) -or -not $keyMap.ContainsKey($sk)) { continue }
            $cloudKey = $keyMap[$sk].CloudKey
            $wls = @(Get-Prop $rec "worklogs")
            if (-not $wls.Count) { Add-Done "worklogs" $sk $done; continue }
            $n = 0; $err = 0
            foreach ($w in $wls) {
                $secs = [int](Get-Prop $w "timeSpentSec"); if ($secs -le 0) { continue }
                $who = [string](Get-Prop $w "author"); $cmtTxt = [string](Get-Prop $w "comment")
                $body = @{ timeSpentSeconds = $secs }
                $started = [string](Get-Prop $w "started"); if ($started) { $body.started = $started }
                $adf = ConvertTo-Adf -Text ("[Migrated worklog — $who]`n$cmtTxt"); if ($adf) { $body.comment = $adf }
                try {
                    Invoke-Api -Uri "$JiraCloudUrl/rest/api/3/issue/$cloudKey/worklog" -Method Post -Headers $cloudHeaders `
                        -Body ($body | ConvertTo-Json -Depth 100) -Channel "cloud-jira" -ThrottleMs $CloudThrottleMs -Idempotent:$false | Out-Null
                    $n++
                } catch { $err++; Write-Log "  [$sk] worklog failed: $($_.Exception.Message)" "ERROR" }
            }
            if ($wls.Count) { Write-Log "  [$sk] -> $cloudKey : $n/$($wls.Count) worklogs" "SUCCESS" }
            if ($err -eq 0) { Add-Done "worklogs" $sk $done }
        }
    }
}

# ===================================================================
# STEP: usermap (utility)
# ===================================================================
function Step-UserMap {
    Write-Section "STEP: USER MAP TEMPLATE"
    $users = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($serverType in $createOrder) {
        foreach ($file in (Get-Records $serverType)) {
            $rec = Read-Json $file.FullName
            foreach ($u in @((Get-Prop $rec.jira.reporter "name"), (Get-Prop $rec.jira.assignee "name"))) { if ($u) { [void]$users.Add([string]$u) } }
            foreach ($c in @($rec.comments)) { $u = Get-Prop $c "authorName"; if ($u) { [void]$users.Add([string]$u) } }
            foreach ($run in @(Get-Prop $rec.xray "runs")) {
                $u = Get-Prop $run "executedBy"; if ($u) { [void]$users.Add([string]$u) }
                $a = Get-Prop $run "assignee";   if ($a) { [void]$users.Add([string]$a) }
            }
        }
    }
    $tpl = Join-Path $exportRoot "_user_map_template.csv"
    $users | Sort-Object | ForEach-Object { [pscustomobject]@{ ServerUsername = $_; CloudAccountId = "" } } |
        Export-Csv -Path $tpl -NoTypeInformation -Encoding UTF8
    Write-Log "Wrote $($users.Count) distinct usernames -> $tpl" "SUCCESS"
    Write-Log "Fill in CloudAccountId (GET /rest/api/3/user/search?query=email), save as _user_map.csv, then re-run results/fields." "WARN"
}

# ===================================================================
# MAIN
# ===================================================================
Write-Section "PHASE 2 — IMPORT: $ServerProjectKey -> $CloudProjectKey"
Write-Log "Cloud URL    : $JiraCloudUrl"
Write-Log "Xray Cloud   : $XrayCloudBase"
Write-Log "Steps        : $($Steps -join ', ')"

$start = Get-Date
foreach ($step in $Steps) {
    switch ($step.ToLowerInvariant()) {
        "issues"       { Step-Issues }
        "associations" { Step-Associations }
        "attachments"  { Step-Attachments }
        "comments"     { Step-Comments }
        "links"        { Step-Links }
        "results"      { Step-Results }
        "fields"       { Step-Fields }
        "worklogs"     { Step-Worklogs }
        "usermap"      { Step-UserMap }
        default        { Write-Log "Unknown step '$step' — skipping." "WARN" }
    }
}
$elapsed = (Get-Date) - $start

Write-Section "IMPORT SUMMARY"
Write-Host "  Duration : $([math]::Round($elapsed.TotalMinutes,1)) min" -ForegroundColor Cyan
Write-Host "  Mapped   : $($keyMap.Count) issues" -ForegroundColor Green
Write-Host "  Key map  : $keyMapFile" -ForegroundColor Cyan
Write-Host "  Log      : $logFile" -ForegroundColor Cyan
if (Test-Path $errorFile) {
    $errCount = (Get-Content $errorFile | Where-Object { $_ -match '\[ERROR\]' } | Measure-Object).Count
    if ($errCount) { Write-Host "  Errors   : $errCount (see $errorFile)" -ForegroundColor Red }
}
Write-Log "Import run complete. Steps=$($Steps -join ',') Mapped=$($keyMap.Count)"
