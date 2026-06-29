# ===================================================================
# PHASE 1 — LOSSLESS EXPORT FROM JIRA SERVER 8.4.0 + XRAY SERVER/DC
# ===================================================================
#
# Produces a complete, self-describing backup of every Xray issue in the
# source project, including the data the plain Jira REST/XML export CANNOT
# see: test type, manual steps (+ per-step attachments), Gherkin / Generic
# definitions, preconditions, Test Set/Plan/Execution memberships, full
# test-run results (per-step status, evidence, defects) AND data-driven
# iteration/example results.
#
# OUTPUT LAYOUT  (under .\export\<PROJECT>\):
#   issues\<IssueType>\<KEY>.json        one rich record per issue
#   attachments\<KEY>\<id>_<file>        downloaded issue attachments
#   xray\steps\<KEY>\stepN\...           downloaded manual-step attachments
#   xray\evidence\<TE>\<T>\...           downloaded run/step evidence
#   features\<KEY>.zip                   Cucumber .feature exports
#   _index.csv  _fields.csv  _manifest_*.csv  _export.log
#
# RESUMABLE: re-running skips issues whose <KEY>.json already exists.
# The export directory IS your full backup — even data the import cannot
# perfectly reconstruct (original authors/dates, custom-field internals)
# is preserved here verbatim.
#
# Reference APIs (verified 2026-06):
#   Jira Server 8.4.0 : /rest/api/2/search, /rest/api/2/issue, /rest/api/2/field
#   Xray Server/DC    : /rest/raven/1.0/api/...  and  /rest/raven/1.0/export/test
# ===================================================================

[CmdletBinding()]
param(
    [string]$JiraServerUrl    = "https://dta-jira.jpadc.corpintra.net/jira",
    [string]$ServerProjectKey = "MFTBCTRKD",
    [string]$RavenVersion     = "1.0",          # 1.0 is the safe choice on Jira 8.4.0
    [int]   $PageSize         = 100,            # search page size (server caps at jira.search.views.default.max, default 1000)
    [int]   $ServerThrottleMs = 0,              # raise (e.g. 100) if the server complains
    [int]   $MaxIssuesPerType = 0,              # 0 = all; set small (e.g. 5) for a dry run
    [switch]$SkipResults,                       # skip test-run/result export (faster, lossy)
    [switch]$SkipAttachments,                   # skip binary downloads (metadata still captured)
    [bool]  $IncludeChangelog = $true,          # capture full change history (large; backup only)
    [bool]  $IncludeWorklog   = $true,          # capture worklogs (time tracking)
    [bool]  $AllowInsecureSource = $true        # trust the self-signed source TLS cert
)

. "$PSScriptRoot\XrayMig.Common.ps1"
Initialize-XrayMig
if ($AllowInsecureSource) { Enable-InsecureSource -Url $JiraServerUrl }

# ===================================================================
# PATHS
# ===================================================================
$exportRoot   = Join-Path $PSScriptRoot "export\$ServerProjectKey"
$issuesRoot   = Join-Path $exportRoot "issues"
$attachRoot   = Join-Path $exportRoot "attachments"
$stepAttRoot  = Join-Path $exportRoot "xray\steps"
$evidenceRoot = Join-Path $exportRoot "xray\evidence"
$featureRoot  = Join-Path $exportRoot "features"
$indexFile    = Join-Path $exportRoot "_index.csv"
$fieldsFile   = Join-Path $exportRoot "_fields.csv"
$logFile      = Join-Path $exportRoot "_export.log"
$errorFile    = Join-Path $exportRoot "_export_errors.log"

foreach ($d in @($exportRoot,$issuesRoot,$attachRoot,$stepAttRoot,$evidenceRoot,$featureRoot)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
Set-LogFiles -LogFile $logFile -ErrorFile $errorFile

# ===================================================================
# DEPENDENCY-SAFE ORDER  (Server issue-type display names)
# ===================================================================
$issueTypeOrder = @("Pre-Condition","Test","Test Set","Test Execution","Test Plan","Sub Test Execution")

# ===================================================================
# SMALL HELPERS
# ===================================================================
function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# Pull the most useful text out of a raven {raw,rendered} field or a plain value.
function Get-RavenText {
    param($Value)
    if ($null -eq $Value) { return "" }
    if ($Value -is [string]) { return $Value }
    $raw = Get-Prop $Value "raw"
    if ($null -ne $raw) { return [string]$raw }
    $rendered = Get-Prop $Value "rendered"
    if ($null -ne $rendered) { return (ConvertFrom-HtmlToText ([string]$rendered)) }
    return [string]$Value
}

# ===================================================================
# AUTH
# ===================================================================
Write-Section "JIRA SERVER LOGIN"
$srvUser = Get-PlainValue  -EnvVarName "XRAY_SRV_USER" -Prompt "Enter Jira Server Username"
$srvPass = Get-SecretValue -EnvVarName "XRAY_SRV_PASS" -Prompt "Enter Jira Server Password"
$srvHeaders = New-BasicAuthHeader -User $srvUser -Secret $srvPass
$srvPass = $null

try {
    $me = Invoke-Api -Uri "$JiraServerUrl/rest/api/2/myself" -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
    Write-Log "Connected to Jira Server as: $($me.displayName)" "SUCCESS"
} catch {
    Write-Log "Cannot connect to Jira Server: $($_.Exception.Message)" "ERROR"
    Write-Log "If this is a TLS trust error, ensure -AllowInsecureSource is set (default true)." "WARN"
    exit 1
}

$ravenBase = "$JiraServerUrl/rest/raven/$RavenVersion/api"
# raven v2.0 renamed the Test step sub-resource to the plural '/steps'.
$stepSubResource = if ($RavenVersion -like "2.*") { "steps" } else { "step" }

# ===================================================================
# FIELD MAP  (id -> name + schema.custom)  used to label all fields
# ===================================================================
Write-Section "DISCOVERING FIELDS"
$fieldMap = @{}
try {
    $allFields = Invoke-Api -Uri "$JiraServerUrl/rest/api/2/field" -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
    foreach ($f in $allFields) {
        $schemaCustom = ""
        $schema = Get-Prop $f "schema"
        if ($schema) { $schemaCustom = [string](Get-Prop $schema "custom") }
        $fieldMap[$f.id] = [pscustomobject]@{ Name = $f.name; Custom = $schemaCustom }
    }
    $fieldMap.GetEnumerator() |
        ForEach-Object { [pscustomobject]@{ Id = $_.Key; Name = $_.Value.Name; SchemaCustom = $_.Value.Custom } } |
        Sort-Object Id | Export-Csv -Path $fieldsFile -NoTypeInformation -Encoding UTF8
    Write-Log "Mapped $($fieldMap.Count) fields -> $fieldsFile" "SUCCESS"
} catch {
    Write-Log "Could not read /rest/api/2/field (continuing without names): $($_.Exception.Message)" "WARN"
}

function Get-FieldName { param([string]$Id) if ($fieldMap.ContainsKey($Id)) { return $fieldMap[$Id].Name } else { return $Id } }

# Find the first custom field id whose NAME (or Xray plugin schema key) matches.
function Find-FieldIdByName {
    param([string[]]$Patterns, [string[]]$SchemaKeys)
    foreach ($id in $fieldMap.Keys) {
        if ($id -notlike "customfield_*") { continue }
        $n = $fieldMap[$id].Name
        $sc = $fieldMap[$id].Custom
        if ($SchemaKeys) { foreach ($sk in $SchemaKeys) { if ($sc -and $sc -imatch $sk) { return $id } } }
        if ($Patterns)   { foreach ($pat in $Patterns)  { if ($n -and $n -imatch $pat) { return $id } } }
    }
    return $null
}

# Pre-resolve the Xray definition fields (instance-specific ids); prefer the
# Xray plugin schema keys (com.xpandit.plugins.xray:*) which are stable.
$fidGenericDef = Find-FieldIdByName -Patterns @('^Generic Test Definition$','Generic.*Definition') -SchemaKeys @('xray:generic-test-definition')
$fidGherkin    = Find-FieldIdByName -Patterns @('^Cucumber Scenario$','Gherkin','Scenario$')        -SchemaKeys @('xray:steps-editor-custom-field','xray:automated-test-type-custom-field')
$fidTestType   = Find-FieldIdByName -Patterns @('^Test Type$')                                      -SchemaKeys @('xray:test-type-custom-field')
$fidRepoPath   = Find-FieldIdByName -Patterns @('Test Repository Path','Repository Path')
$fidPreType    = Find-FieldIdByName -Patterns @('^Precondition Type$','Pre-Condition Type')         -SchemaKeys @('xray:precondition-type-custom-field')
$fidPreCond    = Find-FieldIdByName -Patterns @('^Condition$','Conditions')                          -SchemaKeys @('xray:manual-test-steps-custom-field')
$fidTestEnv    = Find-FieldIdByName -Patterns @('^Test Environments$','Environments$')              -SchemaKeys @('xray:testenvironments-custom-field')

# ===================================================================
# ATTACHMENT DOWNLOAD (with integrity check on resume)
# ===================================================================
function Save-Binary {
    param([string]$Url, [string]$LocalPath, [long]$ExpectedSize = -1)
    if ([string]::IsNullOrWhiteSpace($Url) -or $SkipAttachments) { return $false }
    if (Test-Path $LocalPath) {
        # Resume: trust an existing file ONLY if its size matches (when known)
        # and it is non-empty — otherwise a truncated prior download is re-fetched.
        $len = (Get-Item $LocalPath).Length
        if ($len -gt 0 -and ($ExpectedSize -lt 0 -or $len -eq $ExpectedSize)) { return $true }
        Write-Log "    Re-downloading (size mismatch: have $len, expect $ExpectedSize): $LocalPath" "DEBUG"
    }
    $bytes = Invoke-ApiBytes -Uri $Url -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
    [System.IO.File]::WriteAllBytes($LocalPath, $bytes)
    return $true
}

function Save-IssueAttachments {
    param($Issue, [string]$Key)
    $result = @()
    $atts = Get-Prop $Issue.fields "attachment"
    if (-not $atts) { return $result }
    $dir = Join-Path $attachRoot $Key
    foreach ($a in $atts) {
        $meta = [ordered]@{
            id        = $a.id
            filename  = $a.filename
            mimeType  = (Get-Prop $a "mimeType")
            size      = (Get-Prop $a "size")
            author    = (Get-Prop (Get-Prop $a "author") "name")
            created   = (Get-Prop $a "created")
            content   = $a.content
            localPath = ""
        }
        if (-not $SkipAttachments) {
            try {
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $safe  = Get-SafeFileName ("{0}_{1}" -f $a.id, $a.filename)
                $local = Join-Path $dir $safe
                $sz = -1; try { $sz = [long](Get-Prop $a "size") } catch {}
                if (Save-Binary -Url $a.content -LocalPath $local -ExpectedSize $sz) { $meta.localPath = $local }
            } catch {
                Write-Log "    Attachment download failed ($($a.filename)): $($_.Exception.Message)" "WARN"
            }
        }
        $result += [pscustomobject]$meta
    }
    return $result
}

# Download an arbitrary Xray fileURL (step/run evidence) into a folder.
function Save-XrayBinary {
    param([string]$Url, [string]$Folder, [string]$FileName, [long]$ExpectedSize = -1)
    if ([string]::IsNullOrWhiteSpace($Url) -or $SkipAttachments) { return "" }
    try {
        if (-not (Test-Path $Folder)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }
        $local = Join-Path $Folder (Get-SafeFileName $FileName)
        if (Save-Binary -Url $Url -LocalPath $local -ExpectedSize $ExpectedSize) { return $local }
        return ""
    } catch {
        Write-Log "    Evidence download failed ($FileName): $($_.Exception.Message)" "WARN"
        return ""
    }
}

# ===================================================================
# COMMENTS  (always fetch via the dedicated endpoint with renderedBody,
# so we get clean HTML — search's renderedFields does NOT render comment
# bodies, which otherwise leaves Cloud importing raw wiki markup. Also
# captures visibility so restricted comments are not made public on import.)
# ===================================================================
function Get-AllComments {
    param($Issue, [string]$Key)
    $field = Get-Prop $Issue.fields "comment"
    $total = if ($field) { [int](Get-Prop $field "total") } else { 0 }
    if ($total -le 0) { return @() }

    $out = @()
    $start = 0
    while ($true) {
        try {
            $resp = Invoke-Api -Uri "$JiraServerUrl/rest/api/2/issue/$Key/comment?startAt=$start&maxResults=100&orderBy=created&expand=renderedBody" `
                        -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
        } catch {
            Write-Log "    Could not fetch comments for $Key : $($_.Exception.Message)" "WARN"
            break
        }
        $batch = @($resp.comments)
        foreach ($c in $batch) {
            $out += [pscustomobject]@{
                id         = [string](Get-Prop $c "id")
                author     = (Get-Prop (Get-Prop $c "author") "displayName")
                authorName = (Get-Prop (Get-Prop $c "author") "name")
                created    = (Get-Prop $c "created")
                updated    = (Get-Prop $c "updated")
                body       = (Get-Prop $c "body")
                bodyHtml   = (Get-Prop $c "renderedBody")
                visibility = (Get-Prop $c "visibility")
            }
        }
        $start += $batch.Count
        if ($batch.Count -eq 0 -or $start -ge [int]$resp.total) { break }
    }
    return $out
}

# ===================================================================
# WORKLOGS
# ===================================================================
function Get-AllWorklogs {
    param([string]$Key)
    if (-not $IncludeWorklog) { return @() }
    $out = @()
    try {
        $start = 0
        while ($true) {
            $resp = Invoke-Api -Uri "$JiraServerUrl/rest/api/2/issue/$Key/worklog?startAt=$start&maxResults=100" -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
            $batch = @($resp.worklogs)
            foreach ($w in $batch) {
                $out += [pscustomobject]@{
                    author       = (Get-Prop (Get-Prop $w "author") "name")
                    started      = (Get-Prop $w "started")
                    timeSpent    = (Get-Prop $w "timeSpent")
                    timeSpentSec = (Get-Prop $w "timeSpentSeconds")
                    comment      = (Get-RavenText (Get-Prop $w "comment"))
                }
            }
            $start += $batch.Count
            if ($batch.Count -eq 0 -or $start -ge [int]$resp.total) { break }
        }
    } catch { Write-Log "    worklog fetch failed for $Key : $($_.Exception.Message)" "WARN" }
    return $out
}

# ===================================================================
# CUSTOM FIELDS  (capture EVERYTHING non-null -> backup completeness)
# ===================================================================
function Get-AllCustomFields {
    param($Issue)
    $out = [ordered]@{}
    foreach ($p in $Issue.fields.PSObject.Properties) {
        if ($p.Name -notlike "customfield_*") { continue }
        if ($null -eq $p.Value) { continue }
        $out[$p.Name] = [pscustomobject]@{ name = (Get-FieldName $p.Name); value = $p.Value }
    }
    return $out
}

# ===================================================================
# XRAY: TEST  (type, steps, gherkin, generic, preconditions, repo path)
# ===================================================================
function Get-XrayTestData {
    param([string]$Key, $Issue)

    $data = [ordered]@{
        testType      = ""
        scenarioType  = ""
        manualSteps   = @()
        gherkin       = ""
        unstructured  = ""
        repositoryPath= ""
        preconditions = @()
        featureFile   = ""
    }

    # --- Test type + definition via raven export ---
    # IMPORTANT: raven returns the Gherkin/Generic body under 'definition'
    # (NOT 'scenario'). Branch by the test kind so a Cucumber scenario is
    # stored as gherkin and a Generic body as unstructured.
    try {
        $exp = Invoke-Api -Uri "$ravenBase/test?keys=$Key" -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
        $t = if ($exp -is [array]) { $exp[0] } else { $exp }
        if ($t) {
            $tt = Get-Prop $t "testType"
            if (-not $tt) { $tt = Get-Prop $t "type" }
            if ($tt) { $data.testType = if ($tt -is [string]) { $tt } else { [string](Get-Prop $tt "name") } }
            $data.scenarioType = [string](Get-Prop $t "scenarioType")

            $definition = Get-Prop $t "definition"
            if ($definition) {
                if ($data.testType -imatch 'cucumber|gherkin|bdd' -or $data.scenarioType) {
                    $data.gherkin = [string]$definition
                } else {
                    $data.unstructured = [string]$definition
                }
            }
            # Some versions also expose 'scenario' for Cucumber — use it if present.
            $sc = Get-Prop $t "scenario"; if ($sc -and -not $data.gherkin) { $data.gherkin = [string]$sc }
        }
    } catch { Write-Log "    raven /test export failed for $Key : $($_.Exception.Message)" "WARN" }

    # --- Manual steps (v1 flat shape: step/data/result each {raw,rendered}) ---
    try {
        $steps = Invoke-Api -Uri "$ravenBase/test/$Key/$stepSubResource" -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
        $idx = 0
        foreach ($s in $steps) {
            $idx++
            $stepAtts = @()
            foreach ($att in @(Get-Prop $s "attachments")) {
                $fn  = [string](Get-Prop $att "fileName"); if (-not $fn) { $fn = [string](Get-Prop $att "filename") }
                $url = [string](Get-Prop $att "fileURL");  if (-not $url){ $url = [string](Get-Prop $att "fileUrl") }
                $sz = -1; try { $sz = [long](Get-Prop $att "fileSize") } catch {}
                $sdir = Join-Path (Join-Path $stepAttRoot $Key) "step$idx"
                $lp  = Save-XrayBinary -Url $url -Folder $sdir -FileName ("{0}_{1}" -f (Get-Prop $att "id"), $fn) -ExpectedSize $sz
                $stepAtts += [pscustomobject]@{ id=(Get-Prop $att "id"); fileName=$fn; mimeType=(Get-MimeType $fn); fileURL=$url; localPath=$lp }
            }
            $data.manualSteps += [pscustomobject]@{
                id      = (Get-Prop $s "id")
                index   = if (Get-Prop $s "index") { Get-Prop $s "index" } else { $idx }
                action  = (Get-RavenText (Get-Prop $s "step"))
                data    = (Get-RavenText (Get-Prop $s "data"))
                result  = (Get-RavenText (Get-Prop $s "result"))
                attachments = $stepAtts
            }
        }
    } catch { Write-Log "    raven step fetch failed for $Key : $($_.Exception.Message)" "WARN" }

    # --- Preconditions (returns id,rank,key,type,condition directly) ---
    try {
        $pre = Invoke-Api -Uri "$ravenBase/test/$Key/preconditions" -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
        foreach ($p in $pre) {
            $data.preconditions += [pscustomobject]@{
                key       = (Get-Prop $p "key")
                rank      = (Get-Prop $p "rank")
                type      = (Get-Prop $p "type")
                condition = (Get-RavenText (Get-Prop $p "condition"))
            }
        }
    } catch { Write-Log "    raven preconditions fetch failed for $Key : $($_.Exception.Message)" "WARN" }

    # --- Definition / type / repo path fallbacks from custom fields ---
    if (-not $data.gherkin      -and $fidGherkin)    { $v = Get-Prop $Issue.fields $fidGherkin;    if ($v) { $data.gherkin      = (Get-RavenText $v) } }
    if (-not $data.unstructured -and $fidGenericDef) { $v = Get-Prop $Issue.fields $fidGenericDef; if ($v) { $data.unstructured = (Get-RavenText $v) } }
    if (-not $data.testType     -and $fidTestType)   { $v = Get-Prop $Issue.fields $fidTestType;   if ($v) { $data.testType     = (Get-RavenText $v) } }
    if ($fidRepoPath) { $v = Get-Prop $Issue.fields $fidRepoPath; if ($v) { $data.repositoryPath = (Get-RavenText $v) } }

    # --- Lossless Gherkin export to .feature (Cucumber only) ---
    if ($data.testType -imatch "Cucumber" -or $data.gherkin) {
        try {
            $fp = Join-Path $featureRoot "$Key.zip"
            $bytes = Invoke-ApiBytes -Uri "$JiraServerUrl/rest/raven/$RavenVersion/export/test?keys=$Key&fz=true" `
                        -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
            [System.IO.File]::WriteAllBytes($fp, $bytes)
            $data.featureFile = $fp
        } catch { Write-Log "    .feature export failed for $Key : $($_.Exception.Message)" "WARN" }
    }

    return $data
}

# ===================================================================
# XRAY: PRE-CONDITION issue (its own type + definition)
# ===================================================================
function Get-XrayPreconditionData {
    param([string]$Key, $Issue)
    $type = ""; $cond = ""
    if ($fidPreType) { $v = Get-Prop $Issue.fields $fidPreType; if ($v) { $type = (Get-RavenText $v) } }
    if ($fidPreCond) { $v = Get-Prop $Issue.fields $fidPreCond; if ($v) { $cond = (Get-RavenText $v) } }
    # Cross-fill from the reverse direction (precondition -> tests) if the
    # custom-field names did not resolve the body. This guards against
    # localized/renamed fields silently dropping the precondition definition.
    if ([string]::IsNullOrWhiteSpace($cond)) {
        try {
            $rev = Invoke-Api -Uri "$ravenBase/precondition/$Key/test" -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
            # Some versions return the condition on the precondition object via the test list; if not, leave blank.
            if ($rev) { $first = if ($rev -is [array]) { $rev[0] } else { $rev }; $c = Get-Prop $first "condition"; if ($c) { $cond = (Get-RavenText $c) } }
        } catch {}
    }
    return [pscustomobject]@{ conditionType = $type; condition = $cond }
}

# ===================================================================
# XRAY: TEST SET / TEST PLAN memberships
# ===================================================================
function Get-RavenMemberKeys {
    # Xray raven caps membership responses at 200 items per request (testexec/test,
    # testset/test, testplan/test, testplan/testexecution). A Test Execution / Set /
    # Plan with >200 members 400s without pagination, so page through with page/limit.
    param([string]$Url, [int]$Limit = 100)   # stay safely under the raven 200/req cap
    $keys = @()
    $page = 1
    while ($true) {
        $sep     = if ($Url -match '\?') { '&' } else { '?' }
        $pageUrl = "$Url${sep}page=$page&limit=$Limit"
        try {
            $resp = Invoke-Api -Uri $pageUrl -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
        } catch {
            Write-Log "    membership fetch failed ($pageUrl): $($_.Exception.Message)" "WARN"
            break
        }
        if ($null -eq $resp) { break }
        $batch = @($resp)
        if ($batch.Count -eq 0) { break }
        foreach ($x in $batch) {
            if ($null -eq $x) { continue }
            $keys += [pscustomobject]@{ key=(Get-Prop $x "key"); rank=(Get-Prop $x "rank"); status=(Get-Prop $x "status") }
        }
        if ($batch.Count -lt $Limit) { break }   # last page
        $page++
    }
    return $keys
}

# ===================================================================
# XRAY: TEST EXECUTION runs + results (incl. data-driven iterations)
# ===================================================================
function Get-XrayExecutionData {
    param([string]$Key, $Issue)

    $tests = Get-RavenMemberKeys -Url "$ravenBase/testexec/$Key/test"
    $runs  = @()

    # Test Environments (Xray run environment, distinct from the Jira 'environment' field)
    $testEnvironments = @()
    if ($fidTestEnv -and $Issue) {
        $v = Get-Prop $Issue.fields $fidTestEnv
        if ($v) { foreach ($e in @($v)) { if ($e) { $testEnvironments += [string]$e } } }
    }

    if (-not $SkipResults) {
        foreach ($t in $tests) {
            $tk = $t.key
            if ([string]::IsNullOrWhiteSpace($tk)) { continue }
            try {
                $run = Invoke-Api -Uri "$ravenBase/testrun?testExecIssueKey=$Key&testIssueKey=$tk" `
                            -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
                if (-not $run) { continue }
                $runId = Get-Prop $run "id"

                # Run-level evidence
                $runEvid = @()
                foreach ($e in (Get-Prop $run "evidences")) {
                    $fn  = [string](Get-Prop $e "fileName"); if (-not $fn) { $fn = [string](Get-Prop $e "filename") }
                    $url = [string](Get-Prop $e "fileURL")
                    $sz = -1; try { $sz = [long](Get-Prop $e "fileSize") } catch {}
                    $dir = Join-Path (Join-Path $evidenceRoot $Key) $tk
                    $lp  = Save-XrayBinary -Url $url -Folder $dir -FileName ("{0}_{1}" -f (Get-Prop $e "id"), $fn) -ExpectedSize $sz
                    $runEvid += [pscustomobject]@{ fileName=$fn; mimeType=(Get-MimeType $fn); fileURL=$url; localPath=$lp }
                }

                # Defects (keep full key list, including cross-project defects)
                $runDefects = @()
                foreach ($d in (Get-Prop $run "defects")) { $runDefects += (Get-Prop $d "key") }

                # Step results
                $stepResults = @()
                try {
                    $rsteps = Invoke-Api -Uri "$ravenBase/testrun/$runId/step" -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
                    $si = 0
                    foreach ($rs in $rsteps) {
                        $si++
                        $sEvid = @()
                        foreach ($e in (Get-Prop $rs "evidences")) {
                            $fn  = [string](Get-Prop $e "fileName"); if (-not $fn) { $fn = [string](Get-Prop $e "filename") }
                            $url = [string](Get-Prop $e "fileURL")
                            $sz = -1; try { $sz = [long](Get-Prop $e "fileSize") } catch {}
                            $dir = Join-Path (Join-Path (Join-Path $evidenceRoot $Key) $tk) "step$si"
                            $lp  = Save-XrayBinary -Url $url -Folder $dir -FileName ("{0}_{1}" -f (Get-Prop $e "id"), $fn) -ExpectedSize $sz
                            $sEvid += [pscustomobject]@{ fileName=$fn; mimeType=(Get-MimeType $fn); fileURL=$url; localPath=$lp }
                        }
                        $sDef = @()
                        foreach ($d in (Get-Prop $rs "defects")) { $sDef += (Get-Prop $d "key") }
                        $stepResults += [pscustomobject]@{
                            index        = if (Get-Prop $rs "index") { Get-Prop $rs "index" } else { $si }
                            status       = (Get-Prop $rs "status")
                            comment      = (Get-RavenText (Get-Prop $rs "comment"))
                            actualResult = (Get-RavenText (Get-Prop $rs "actualResult"))
                            evidence     = $sEvid
                            defects      = $sDef
                        }
                    }
                } catch { Write-Log "    run step results failed ($Key/$tk): $($_.Exception.Message)" "WARN" }

                $runs += [pscustomobject]@{
                    testKey    = $tk
                    runId      = $runId
                    status     = (Get-Prop $run "status")
                    executedBy = (Get-Prop $run "executedBy")
                    assignee   = (Get-Prop $run "assignee")
                    startedOn  = (Get-Prop $run "startedOn")
                    finishedOn = (Get-Prop $run "finishedOn")
                    comment    = (Get-RavenText (Get-Prop $run "comment"))
                    defects    = $runDefects
                    evidence   = $runEvid
                    steps      = $stepResults
                    # Data-driven / BDD iteration results — captured raw so they are
                    # not lost even if per-iteration import is best-effort.
                    examples   = (Get-Prop $run "examples")
                    iterations = (Get-Prop $run "iterations")
                }
            } catch { Write-Log "    testrun fetch failed ($Key/$tk): $($_.Exception.Message)" "WARN" }
        }
    }

    return [pscustomobject]@{ tests = $tests; runs = $runs; testEnvironments = $testEnvironments }
}

# ===================================================================
# BUILD ONE ISSUE RECORD
# ===================================================================
function Build-IssueRecord {
    param($Issue, [string]$ServerType)

    $key       = $Issue.key
    $f         = $Issue.fields
    $rendered  = Get-Prop $Issue "renderedFields"

    $record = [ordered]@{
        serverKey   = $key
        serverId    = $Issue.id
        issueType   = $ServerType
        exportedAt  = (Get-Date -Format "o")
        jira        = [ordered]@{
            summary      = (Get-Prop $f "summary")
            description  = (Get-Prop $f "description")
            descriptionHtml = if ($rendered) { Get-Prop $rendered "description" } else { $null }
            status       = (Get-Prop (Get-Prop $f "status") "name")
            resolution   = (Get-Prop (Get-Prop $f "resolution") "name")
            priority     = (Get-Prop (Get-Prop $f "priority") "name")
            labels       = @(Get-Prop $f "labels")
            components   = @((Get-Prop $f "components") | ForEach-Object { Get-Prop $_ "name" })
            fixVersions  = @((Get-Prop $f "fixVersions") | ForEach-Object { Get-Prop $_ "name" })
            affectsVersions = @((Get-Prop $f "versions") | ForEach-Object { Get-Prop $_ "name" })
            environment  = (Get-Prop $f "environment")
            duedate      = (Get-Prop $f "duedate")
            created      = (Get-Prop $f "created")
            updated      = (Get-Prop $f "updated")
            reporter     = [ordered]@{
                name        = (Get-Prop (Get-Prop $f "reporter") "name")
                displayName = (Get-Prop (Get-Prop $f "reporter") "displayName")
                email       = (Get-Prop (Get-Prop $f "reporter") "emailAddress")
            }
            assignee     = [ordered]@{
                name        = (Get-Prop (Get-Prop $f "assignee") "name")
                displayName = (Get-Prop (Get-Prop $f "assignee") "displayName")
                email       = (Get-Prop (Get-Prop $f "assignee") "emailAddress")
            }
            parentKey    = (Get-Prop (Get-Prop $f "parent") "key")
            customFields = (Get-AllCustomFields -Issue $Issue)
        }
        comments    = (Get-AllComments -Issue $Issue -Key $key)
        worklogs    = (Get-AllWorklogs -Key $key)
        attachments = (Save-IssueAttachments -Issue $Issue -Key $key)
        issueLinks  = @()
        changelog   = if ($IncludeChangelog) { Get-Prop $Issue "changelog" } else { $null }
        xray        = $null
    }

    foreach ($l in (Get-Prop $f "issuelinks")) {
        $type = Get-Prop $l "type"
        if (Get-Prop $l "outwardIssue") {
            $record.issueLinks += [pscustomobject]@{ direction="outward"; typeName=(Get-Prop $type "name"); label=(Get-Prop $type "outward"); linkedKey=(Get-Prop (Get-Prop $l "outwardIssue") "key") }
        } elseif (Get-Prop $l "inwardIssue") {
            $record.issueLinks += [pscustomobject]@{ direction="inward";  typeName=(Get-Prop $type "name"); label=(Get-Prop $type "inward");  linkedKey=(Get-Prop (Get-Prop $l "inwardIssue") "key") }
        }
    }

    switch ($ServerType) {
        "Test"               { $record.xray = (Get-XrayTestData -Key $key -Issue $Issue) }
        "Pre-Condition"      { $record.xray = (Get-XrayPreconditionData -Key $key -Issue $Issue) }
        "Test Set"           { $record.xray = [pscustomobject]@{ tests = (Get-RavenMemberKeys -Url "$ravenBase/testset/$key/test") } }
        "Test Plan"          { $record.xray = [pscustomobject]@{
                                   tests          = (Get-RavenMemberKeys -Url "$ravenBase/testplan/$key/test")
                                   testExecutions = (Get-RavenMemberKeys -Url "$ravenBase/testplan/$key/testexecution")
                               } }
        "Test Execution"     { $record.xray = (Get-XrayExecutionData -Key $key -Issue $Issue) }
        "Sub Test Execution" { $record.xray = (Get-XrayExecutionData -Key $key -Issue $Issue) }
    }

    return $record
}

# ===================================================================
# EXPORT ONE ISSUE TYPE
# ===================================================================
$masterIndex = [System.Collections.Generic.List[object]]::new()
if (Test-Path $indexFile) { Import-Csv -Path $indexFile -Encoding UTF8 | ForEach-Object { $masterIndex.Add($_) } }

function Save-Index {
    $masterIndex | Group-Object ServerKey | ForEach-Object { $_.Group[-1] } |
        Export-Csv -Path $indexFile -NoTypeInformation -Encoding UTF8
}

function Export-IssueType {
    param([string]$ServerType)

    Write-Section "EXPORTING: $ServerType"
    $typeFolder = Join-Path $issuesRoot (Get-SafeFileName $ServerType)
    if (-not (Test-Path $typeFolder)) { New-Item -ItemType Directory -Path $typeFolder -Force | Out-Null }

    $manifest = [System.Collections.Generic.List[object]]::new()
    $jql      = "project = `"$ServerProjectKey`" AND issuetype = `"$ServerType`" ORDER BY key ASC"
    $encoded  = [uri]::EscapeDataString($jql)
    $startAt  = 0
    $total    = -1
    $count    = 0
    $exported = 0; $skipped = 0; $failed = 0

    do {
        $url = "$JiraServerUrl/rest/api/2/search?jql=$encoded&startAt=$startAt&maxResults=$PageSize&fields=*all&expand=renderedFields,names,changelog"
        try {
            $page = Invoke-Api -Uri $url -Headers $srvHeaders -Channel "server" -ThrottleMs $ServerThrottleMs
        } catch {
            Write-Log "Search failed at startAt=$startAt for '$ServerType': $($_.Exception.Message)" "ERROR"
            break
        }
        $total = [int]$page.total
        if ($page.issues.Count -eq 0) { break }

        foreach ($issue in $page.issues) {
            if ($MaxIssuesPerType -gt 0 -and $count -ge $MaxIssuesPerType) { break }
            $count++

            $key      = $issue.key
            $jsonPath = Join-Path $typeFolder "$key.json"
            $pct      = if ($total) { [math]::Round(($count/$total)*100,1) } else { 0 }
            Write-Log "[$ServerType] $count/$total ($pct%) — $key"

            if (Test-Path $jsonPath) {
                Write-Log "  Already exported — skipping." "DEBUG"
                $skipped++
                $manifest.Add([pscustomobject]@{ ServerKey=$key; IssueType=$ServerType; Summary=(Get-Prop $issue.fields "summary"); FilePath=$jsonPath; Status="SKIPPED" })
                continue
            }

            try {
                $record = Build-IssueRecord -Issue $issue -ServerType $ServerType
                Save-Json -Object $record -Path $jsonPath
                $exported++
                $manifest.Add([pscustomobject]@{ ServerKey=$key; IssueType=$ServerType; Summary=$record.jira.summary; FilePath=$jsonPath; Status="EXPORTED" })
                $masterIndex.Add([pscustomobject]@{ ServerKey=$key; IssueType=$ServerType; ParentKey=$record.jira.parentKey; FilePath=$jsonPath; ExportedAt=$record.exportedAt })
                Write-Log "  Saved $key.json" "SUCCESS"
            } catch {
                $failed++
                Write-Log "  FAILED $key : $($_.Exception.Message)" "ERROR"
                $manifest.Add([pscustomobject]@{ ServerKey=$key; IssueType=$ServerType; Summary=""; FilePath=""; Status="FAILED" })
            }

            if ($count % 50 -eq 0) { Save-Index }
        }

        # Advance by the ACTUAL number returned — the server may cap the page size.
        $startAt += $page.issues.Count
        if ($MaxIssuesPerType -gt 0 -and $count -ge $MaxIssuesPerType) { break }
    } while ($startAt -lt $total)

    $manifestPath = Join-Path $exportRoot ("_manifest_{0}.csv" -f (Get-SafeFileName $ServerType))
    $manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
    Save-Index
    Write-Log "[$ServerType] done — Exported=$exported Skipped=$skipped Failed=$failed" "SUCCESS"
}

# ===================================================================
# MAIN
# ===================================================================
Write-Section "PHASE 1 — LOSSLESS EXPORT: $ServerProjectKey"
Write-Log "Server URL  : $JiraServerUrl"
Write-Log "Export root : $exportRoot"
Write-Log "Raven API   : $ravenBase  (step sub-resource: /$stepSubResource)"
if ($SkipResults)     { Write-Log "SkipResults enabled — test-run results will NOT be exported." "WARN" }
if ($SkipAttachments) { Write-Log "SkipAttachments enabled — binaries will NOT be downloaded." "WARN" }

$start = Get-Date
foreach ($t in $issueTypeOrder) {
    try { Export-IssueType -ServerType $t }
    catch { Write-Log "UNHANDLED error exporting '$t': $($_.Exception.Message)" "ERROR" }
}
$elapsed = (Get-Date) - $start
if ($AllowInsecureSource) { Disable-InsecureSource }

Write-Section "EXPORT SUMMARY"
$jsonCount = (Get-ChildItem -Path $issuesRoot -Recurse -Filter "*.json" -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Host "  Duration    : $([math]::Round($elapsed.TotalMinutes,1)) min" -ForegroundColor Cyan
Write-Host "  Issue files : $jsonCount" -ForegroundColor Green
Write-Host "  Export root : $exportRoot" -ForegroundColor Cyan
Write-Host "  Index       : $indexFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Next: review the export, then run Phase2_Import_Cloud.ps1" -ForegroundColor Yellow
Write-Log "Export complete. Files=$jsonCount Duration=$([math]::Round($elapsed.TotalMinutes,1))min"
