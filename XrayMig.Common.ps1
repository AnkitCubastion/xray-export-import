# ===================================================================
# XrayMig.Common.ps1  —  Shared helpers for the Xray Server -> Cloud
#                        migration (Phase 0 preflight / 1 export / 2 import).
# ===================================================================
#
# Dot-source this from the phase scripts:
#     . "$PSScriptRoot\XrayMig.Common.ps1"
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.
# No external modules required.
#
# Everything here is side-effect free except Initialize-XrayMig (pins TLS)
# and Enable-InsecureSource (installs a cert-trust override scoped to the
# self-signed SOURCE hosts only — never the Cloud target).
#
# Verified against (2026-06):
#   Jira Server 8.4.0 REST   : docs.atlassian.com/software/jira/docs/api/REST/8.4.0
#   Jira Cloud  REST v3      : developer.atlassian.com/cloud/jira/platform/rest/v3
#   Xray Server/DC (raven)   : /rest/raven/1.0/api/... + /rest/raven/1.0/export/test
#   Xray Cloud REST v2       : /api/v2/authenticate, /api/v2/import/execution
#   Xray Cloud GraphQL       : /api/v2/graphql
# ===================================================================

Set-StrictMode -Version Latest

$script:IsPSCore = ($PSVersionTable.PSVersion.Major -ge 6)

# -------------------------------------------------------------------
# Initialise runtime (TLS, console encoding).
# -------------------------------------------------------------------
function Initialize-XrayMig {
    # Negotiate the BROADEST TLS set the platform supports — incl. TLS 1.3 when
    # available. Pinning ONLY TLS 1.2/1.1 (the old behaviour) fails against a
    # server that requires TLS 1.3, which surfaces in Windows PowerShell 5.1 as
    # "The underlying connection was closed: An unexpected error occurred on a
    # send." Including 1.3 lets the handshake succeed (and 1.2 servers still
    # negotiate down).
    try {
        $proto = [Net.SecurityProtocolType]0
        foreach ($name in @('Tls13','Tls12','Tls11','Tls')) {
            try { $proto = $proto -bor [Net.SecurityProtocolType]::$name } catch {}
        }
        if ($proto -ne [Net.SecurityProtocolType]0) { [Net.ServicePointManager]::SecurityProtocol = $proto }
    } catch {
        # If setting an unsupported protocol throws, let Windows Schannel choose
        # (SystemDefault enables TLS 1.3 on Windows 11 + .NET Framework 4.8).
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::SystemDefault } catch {}
    }
    try { [Net.ServicePointManager]::Expect100Continue = $false } catch {}
    # Proxy handling. Corporate networks often reach the internal Jira ONLY via a
    # proxy: the browser uses it, but a DIRECT PowerShell connection can't even
    # resolve the internal DNS name ("The remote name could not be resolved").
    #   $env:XRAY_HTTP_PROXY = "http://proxy.host:8080"  -> force this proxy
    #   $env:XRAY_HTTP_PROXY = "direct"                  -> force a direct connection
    #   (unset)                                          -> use the system/IE proxy
    # NOTE: PowerShell 7 (Core) ALSO natively honours $env:HTTPS_PROXY / $env:HTTP_PROXY,
    # so setting those covers both PS 5.1 (via the WebProxy below) and PS 7.
    try {
        $proxyUrl = $env:XRAY_HTTP_PROXY
        if (-not $proxyUrl) { $proxyUrl = $env:HTTPS_PROXY }
        if (-not $proxyUrl) { $proxyUrl = $env:HTTP_PROXY }
        if ($proxyUrl -and $proxyUrl.Trim().ToLower() -eq 'direct') {
            [System.Net.WebRequest]::DefaultWebProxy = $null
        } elseif ($proxyUrl) {
            $wp = New-Object System.Net.WebProxy($proxyUrl, $false)   # $false = do NOT bypass local; internal hosts must go via the proxy
            $wp.UseDefaultCredentials = $true
            [System.Net.WebRequest]::DefaultWebProxy = $wp
        } else {
            $wp = [System.Net.WebRequest]::GetSystemWebProxy()
            if ($wp) { $wp.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials; [System.Net.WebRequest]::DefaultWebProxy = $wp }
        }
    } catch {}
    try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
}

# -------------------------------------------------------------------
# Self-signed TLS handling for the internal SOURCE hosts.
#   Jira Server 8.4.0 on dta-jira*.corpintra/tbintra serves a self-signed
#   chain that BOTH PS 5.1 and PS 7 reject by default. This is the #1 reason
#   a previous export produced nothing.
#
#   - PS 5.1: Invoke-WebRequest/RestMethod honour ServicePointManager's
#             ServerCertificateValidationCallback — we install one that
#             trusts ONLY the named source hosts.
#   - PS 7+ : the above callback is ignored; callers must pass
#             -SkipCertificateCheck. Test-InsecureHost tells them when to.
#
#   The Cloud target uses normal public TLS and is NEVER trusted blindly.
# -------------------------------------------------------------------
$script:InsecureHosts = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

function Enable-InsecureSource {
    param([Parameter(Mandatory)][string]$Url)
    try { $h = ([uri]$Url).Host } catch { $h = $Url }
    [void]$script:InsecureHosts.Add($h)

    if (-not $script:IsPSCore) {
        # Scope the trust to our source hosts; everything else validates normally.
        $hosts = $script:InsecureHosts
        [Net.ServicePointManager]::ServerCertificateValidationCallback = {
            param($senderObj, $cert, $chain, $errors)
            if ($errors -eq [System.Net.Security.SslPolicyErrors]::None) { return $true }
            try {
                $reqHost = $null
                if ($senderObj -is [System.Net.HttpWebRequest]) { $reqHost = $senderObj.RequestUri.Host }
                elseif ($senderObj -and $senderObj.PSObject.Properties['Host']) { $reqHost = $senderObj.Host }
                if ($reqHost -and $hosts.Contains($reqHost)) { return $true }
            } catch {}
            # If we can't identify the host (some SslStream callers), fall back to the
            # allowlist being non-empty AND export-only context — trust it.
            return ($hosts.Count -gt 0)
        }
    }
    Write-Host "  TLS trust override enabled for source host: $h" -ForegroundColor DarkGray
}

function Disable-InsecureSource {
    $script:InsecureHosts.Clear()
    if (-not $script:IsPSCore) {
        try { [Net.ServicePointManager]::ServerCertificateValidationCallback = $null } catch {}
    }
}

function Test-InsecureHost {
    param([string]$Uri)
    if ($script:InsecureHosts.Count -eq 0) { return $false }
    try { return $script:InsecureHosts.Contains(([uri]$Uri).Host) } catch { return $false }
}

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
$script:LogFile   = $null
$script:ErrorFile = $null

function Set-LogFiles {
    param([string]$LogFile, [string]$ErrorFile)
    $script:LogFile   = $LogFile
    $script:ErrorFile = $ErrorFile
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        "SUCCESS" { "Green"   }
        "WARN"    { "Yellow"  }
        "ERROR"   { "Red"     }
        "DEBUG"   { "DarkGray" }
        default   { "Cyan"    }
    }
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {}
    }
    if ($Level -eq "ERROR" -and $script:ErrorFile) {
        try { Add-Content -Path $script:ErrorFile -Value $line -Encoding UTF8 } catch {}
    }
}

function Write-Section {
    param([string]$Title)
    $bar = "=" * 64
    Write-Host ""; Write-Host $bar -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan; Write-Host ""
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value "`r`n==== $Title ====" -Encoding UTF8 } catch {}
    }
}

# -------------------------------------------------------------------
# Credentials — read from env var first, prompt only if missing.
# Never echoed, never written to disk.
# -------------------------------------------------------------------
function Get-SecretValue {
    param([string]$EnvVarName, [string]$Prompt)
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvVarName)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        Write-Host "  Using $EnvVarName from environment." -ForegroundColor DarkGray
        return $fromEnv
    }
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Get-PlainValue {
    param([string]$EnvVarName, [string]$Prompt)
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvVarName)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { return $fromEnv }
    return Read-Host -Prompt $Prompt
}

function New-BasicAuthHeader {
    param([string]$User, [string]$Secret)
    $pair    = "{0}:{1}" -f $User, $Secret
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))
    return @{
        Authorization  = "Basic $encoded"
        Accept         = "application/json"
        "Content-Type" = "application/json"
    }
}

# -------------------------------------------------------------------
# Throttle — keep below provider rate limits.
#   Xray Cloud: ~300 req / 5 min (Standard) => ~1 req/s. Be polite.
# Per-"channel" minimum interval (ms) between calls.
# -------------------------------------------------------------------
$script:LastCall = @{}
function Wait-Throttle {
    param([string]$Channel, [int]$MinIntervalMs = 0)
    if ($MinIntervalMs -le 0) { return }
    if ($script:LastCall.ContainsKey($Channel)) {
        $elapsed = ((Get-Date) - $script:LastCall[$Channel]).TotalMilliseconds
        $wait    = $MinIntervalMs - $elapsed
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
    }
    $script:LastCall[$Channel] = Get-Date
}

# Push the channel's next-allowed time forward (used after a 429/Retry-After
# so a recovering call does not immediately re-burst).
function Set-ThrottleBackoff {
    param([string]$Channel, [int]$Seconds)
    $script:LastCall[$Channel] = (Get-Date).AddSeconds($Seconds)
}

# -------------------------------------------------------------------
# HTTP error body / status extractor (works for both PS 5.1 and 7+)
# -------------------------------------------------------------------
function Get-HttpErrorBody {
    param($ErrorRecord)
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            return $ErrorRecord.ErrorDetails.Message
        }
    } catch {}
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp -and $resp.GetResponseStream) {
            $stream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body   = $reader.ReadToEnd()
            $reader.Close()
            if (-not [string]::IsNullOrWhiteSpace($body)) { return $body }
        }
    } catch {}
    return $ErrorRecord.Exception.Message
}

function Get-HttpStatusCode {
    param($ErrorRecord)
    try { return [int]$ErrorRecord.Exception.Response.StatusCode.value__ } catch {}
    try { return [int]$ErrorRecord.Exception.Response.StatusCode }        catch {}
    return 0
}

# Parse Retry-After (seconds OR HTTP-date) into seconds; 0 if absent/unparseable.
function Get-RetryAfterSeconds {
    param($ErrorRecord)
    $ra = $null
    try { $ra = $ErrorRecord.Exception.Response.Headers["Retry-After"] } catch {}
    if (-not $ra) { try { $ra = $ErrorRecord.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds } catch {} }
    if (-not $ra) { return 0 }
    $secs = 0.0
    if ([double]::TryParse([string]$ra, [ref]$secs)) { return [int][math]::Ceiling($secs) }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse([string]$ra, [ref]$dt)) {
        $delta = ($dt - (Get-Date)).TotalSeconds
        if ($delta -gt 0) { return [int][math]::Ceiling($delta) }
    }
    return 0
}

# -------------------------------------------------------------------
# Resilient REST call with exponential backoff + 429 Retry-After.
#
#   -Idempotent:$false  -> do NOT retry on 5xx (creates are not idempotent;
#                          a server-side success answered with 502 would
#                          otherwise be retried and create a DUPLICATE issue).
#                          Connection-level failures (code 0) are still NOT
#                          retried for non-idempotent calls.
#   -OnUnauthorized      -> scriptblock invoked once on 401 (e.g. refresh the
#                          Xray Cloud token) before a single retry.
# -------------------------------------------------------------------
function Invoke-Api {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [string]$Method = "Get",
        [hashtable]$Headers,
        $Body,                       # string or object; objects get JSON-encoded
        [string]$ContentType = "application/json; charset=utf-8",
        [string]$Channel = "default",
        [int]$ThrottleMs = 0,
        [int]$MaxRetries = 6,
        [int]$BaseSeconds = 3,
        [int]$TimeoutSec = 300,
        [bool]$Idempotent = $true,
        [scriptblock]$OnUnauthorized
    )

    $bodyBytes = $null
    if ($null -ne $Body) {
        if ($Body -is [string]) { $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body) }
        else { $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 100)) }
    }

    $skipCert  = ($script:IsPSCore -and (Test-InsecureHost $Uri))
    $reAuthed  = $false
    $attempt   = 0
    while ($true) {
        Wait-Throttle -Channel $Channel -MinIntervalMs $ThrottleMs
        try {
            $params = @{
                Uri         = $Uri
                Method      = $Method
                Headers     = $Headers
                TimeoutSec  = $TimeoutSec
                ErrorAction = "Stop"
            }
            if ($null -ne $bodyBytes) { $params.Body = $bodyBytes; $params.ContentType = $ContentType }
            if ($skipCert) { $params.SkipCertificateCheck = $true }
            return Invoke-RestMethod @params
        }
        catch {
            $attempt++
            $code = Get-HttpStatusCode -ErrorRecord $_

            # One-shot re-auth on 401 (e.g. expired Xray Cloud token).
            if ($code -eq 401 -and $OnUnauthorized -and -not $reAuthed) {
                $reAuthed = $true; $attempt--
                Write-Log "  HTTP 401 on $Method $Uri — re-authenticating and retrying once." "WARN"
                try { & $OnUnauthorized } catch { Write-Log "  re-auth failed: $($_.Exception.Message)" "ERROR" }
                # Refresh the Authorization header if the caller stored a new token.
                if ($Headers -and $Headers.ContainsKey("Authorization") -and $script:XrayToken) {
                    $Headers["Authorization"] = "Bearer $script:XrayToken"
                }
                continue
            }

            $retryable = $false
            if ($code -in @(429,500,502,503,504)) { $retryable = $Idempotent -or ($code -eq 429) }
            elseif ($code -eq 0) { $retryable = $Idempotent }   # connection-level: only retry idempotent GETs

            if ($retryable -and $attempt -lt $MaxRetries) {
                $wait = [math]::Pow(2, $attempt) * $BaseSeconds
                $ra   = Get-RetryAfterSeconds -ErrorRecord $_
                if ($ra -gt 0) { $wait = [math]::Max($ra, $wait); Set-ThrottleBackoff -Channel $Channel -Seconds ([int]$wait) }
                Write-Log "  HTTP $code on $Method $Uri — retry $attempt/$MaxRetries in ${wait}s" "WARN"
                Start-Sleep -Seconds ([int]$wait)
            }
            else {
                throw "HTTP $code calling $Method $Uri :: $(Get-HttpErrorBody -ErrorRecord $_)"
            }
        }
    }
}

# -------------------------------------------------------------------
# Resilient binary GET (attachment download / .feature zip export).
# Returns a byte[]. Rejects HTML login pages masquerading as 200.
# -------------------------------------------------------------------
function Invoke-ApiBytes {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [hashtable]$Headers,
        [string]$Channel = "default",
        [int]$ThrottleMs = 0,
        [int]$MaxRetries = 6,
        [int]$BaseSeconds = 3,
        [int]$TimeoutSec = 600
    )
    # Binary GETs should accept anything, not application/json.
    $h = @{}
    if ($Headers) { foreach ($k in $Headers.Keys) { if ($k -ine "Accept" -and $k -ine "Content-Type") { $h[$k] = $Headers[$k] } } }
    $h["Accept"] = "*/*"

    $skipCert = ($script:IsPSCore -and (Test-InsecureHost $Uri))
    $attempt = 0
    while ($true) {
        Wait-Throttle -Channel $Channel -MinIntervalMs $ThrottleMs
        try {
            $p = @{ Uri = $Uri; Headers = $h; Method = "Get"; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ErrorAction = "Stop" }
            if ($skipCert) { $p.SkipCertificateCheck = $true }
            $resp = Invoke-WebRequest @p

            # Reject a login page returned as 200 (wrong/expired session).
            $ctype = ""
            try { $ctype = [string]$resp.Headers["Content-Type"] } catch {}
            if ($ctype -match 'text/html') {
                throw "Expected a binary file but received text/html (likely a login page) from $Uri"
            }

            # RawContentStream gives true bytes on both 5.1 and 7+ (Content is a
            # decoded STRING on 5.1, which corrupts binaries).
            if ($resp.PSObject.Properties['RawContentStream'] -and $resp.RawContentStream) {
                return $resp.RawContentStream.ToArray()
            }
            $c = $resp.Content
            if ($c -is [byte[]]) { return $c }
            return [System.Text.Encoding]::UTF8.GetBytes([string]$c)
        }
        catch {
            $attempt++
            $code = Get-HttpStatusCode -ErrorRecord $_
            $retryable = ($code -in @(429,500,502,503,504)) -or ($code -eq 0)
            if ($retryable -and $attempt -lt $MaxRetries) {
                $wait = [math]::Pow(2, $attempt) * $BaseSeconds
                Write-Log "  HTTP $code downloading $Uri — retry $attempt/$MaxRetries in ${wait}s" "WARN"
                Start-Sleep -Seconds ([int]$wait)
            } else {
                throw "HTTP $code downloading $Uri :: $(Get-HttpErrorBody -ErrorRecord $_)"
            }
        }
    }
}

# -------------------------------------------------------------------
# Multipart upload (Jira Cloud attachment) — manual body so it works
# on Windows PowerShell 5.1 (no -Form). Returns parsed response.
# -------------------------------------------------------------------
function Invoke-MultipartUpload {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [hashtable]$Headers,   # must NOT set Content-Type
        [Parameter(Mandatory)] [string]$FilePath,
        [string]$FileName,
        [string]$Channel = "cloud-jira",
        [int]$ThrottleMs = 0,
        [int]$MaxRetries = 5,
        [int]$BaseSeconds = 3
    )
    if (-not $FileName) { $FileName = Split-Path $FilePath -Leaf }
    $boundary  = "----XrayMig$([Guid]::NewGuid().ToString('N'))"
    $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
    $enc       = [System.Text.Encoding]::UTF8

    $pre  = "--$boundary`r`n" +
            "Content-Disposition: form-data; name=`"file`"; filename=`"$FileName`"`r`n" +
            "Content-Type: application/octet-stream`r`n`r`n"
    $post = "`r`n--$boundary--`r`n"

    $ms = New-Object System.IO.MemoryStream
    $preBytes  = $enc.GetBytes($pre)
    $postBytes = $enc.GetBytes($post)
    $ms.Write($preBytes,  0, $preBytes.Length)
    $ms.Write($fileBytes, 0, $fileBytes.Length)
    $ms.Write($postBytes, 0, $postBytes.Length)
    $bodyBytes = $ms.ToArray()
    $ms.Dispose()

    $h = @{}
    foreach ($k in $Headers.Keys) { if ($k -ieq "Content-Type") { continue }; $h[$k] = $Headers[$k] }
    $h["X-Atlassian-Token"] = "no-check"

    $skipCert = ($script:IsPSCore -and (Test-InsecureHost $Uri))
    $attempt = 0
    while ($true) {
        Wait-Throttle -Channel $Channel -MinIntervalMs $ThrottleMs
        try {
            $p = @{ Uri = $Uri; Method = "Post"; Headers = $h;
                    ContentType = "multipart/form-data; boundary=$boundary";
                    Body = $bodyBytes; ErrorAction = "Stop" }
            if ($skipCert) { $p.SkipCertificateCheck = $true }
            return Invoke-RestMethod @p
        }
        catch {
            $attempt++
            $code = Get-HttpStatusCode -ErrorRecord $_
            # Upload is not idempotent — only retry transient transport failures, not 5xx.
            if ($code -in @(429,503) -and $attempt -lt $MaxRetries) {
                $wait = [math]::Pow(2, $attempt) * $BaseSeconds
                Write-Log "  HTTP $code uploading $FileName — retry $attempt/$MaxRetries in ${wait}s" "WARN"
                Start-Sleep -Seconds ([int]$wait)
            } else {
                throw "HTTP $code uploading $FileName :: $(Get-HttpErrorBody -ErrorRecord $_)"
            }
        }
    }
}

# -------------------------------------------------------------------
# Xray Cloud authentication -> Bearer token (JWT, ~24h validity).
# The token is stored script-scoped so every later call (GraphQL, import)
# reads the CURRENT token and can transparently refresh on 401.
# -------------------------------------------------------------------
$script:XrayToken   = $null
$script:XrayAuth    = $null   # @{ BaseUrl; ClientId; ClientSecret; IssuedAt }

function Set-XrayAuth {
    param([Parameter(Mandatory)][string]$BaseUrl,
          [Parameter(Mandatory)][string]$ClientId,
          [Parameter(Mandatory)][string]$ClientSecret)
    $script:XrayAuth = @{ BaseUrl = $BaseUrl; ClientId = $ClientId; ClientSecret = $ClientSecret; IssuedAt = $null }
    Update-XrayToken
    return $script:XrayToken
}

function Update-XrayToken {
    if (-not $script:XrayAuth) { throw "Set-XrayAuth must be called before Update-XrayToken." }
    $body = @{ client_id = $script:XrayAuth.ClientId; client_secret = $script:XrayAuth.ClientSecret } | ConvertTo-Json
    $resp = Invoke-Api -Uri "$($script:XrayAuth.BaseUrl)/api/v2/authenticate" -Method Post `
                -Headers @{ "Content-Type" = "application/json"; Accept = "application/json" } `
                -Body $body -Channel "xray-auth"
    $token = "$resp".Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($token)) { throw "Xray Cloud authentication returned an empty token." }
    $script:XrayToken      = $token
    $script:XrayAuth.IssuedAt = Get-Date
    return $token
}

# Re-auth proactively if the token is older than $MaxAgeHours (default 20h,
# safely inside the ~24h window) — cheap insurance for very long runs.
function Confirm-XrayTokenFresh {
    param([double]$MaxAgeHours = 20)
    if (-not $script:XrayAuth) { return }
    if (-not $script:XrayAuth.IssuedAt) { return }
    if (((Get-Date) - $script:XrayAuth.IssuedAt).TotalHours -ge $MaxAgeHours) {
        Write-Log "  Xray token nearing expiry — refreshing." "DEBUG"
        Update-XrayToken | Out-Null
    }
}

# -------------------------------------------------------------------
# Xray Cloud GraphQL call. Returns the 'data' object; throws on errors[].
# Auto-refreshes the token on 401.
# -------------------------------------------------------------------
function Invoke-Graphql {
    param(
        [Parameter(Mandatory)] [string]$BaseUrl,
        [Parameter(Mandatory)] [string]$Query,
        $Variables,
        [int]$ThrottleMs = 350
    )
    Confirm-XrayTokenFresh
    $payload = @{ query = $Query }
    if ($null -ne $Variables) { $payload.variables = $Variables }
    $headers = @{ Authorization = "Bearer $script:XrayToken"; Accept = "application/json"; "Content-Type" = "application/json" }
    $resp = Invoke-Api -Uri "$BaseUrl/api/v2/graphql" -Method Post -Headers $headers `
                -Body ($payload | ConvertTo-Json -Depth 100) -Channel "xray-cloud" -ThrottleMs $ThrottleMs `
                -OnUnauthorized { Update-XrayToken | Out-Null }
    if ($resp.PSObject.Properties.Name -contains "errors" -and $resp.errors) {
        $msg = ($resp.errors | ForEach-Object { $_.message }) -join " | "
        throw "GraphQL error: $msg"
    }
    return $resp.data
}

# Xray Cloud REST v2 (e.g. import/execution). Auto-refreshes token on 401.
function Invoke-XrayRest {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [string]$Method = "Post",
        $Body,
        [int]$ThrottleMs = 1100
    )
    Confirm-XrayTokenFresh
    $headers = @{ Authorization = "Bearer $script:XrayToken"; Accept = "application/json"; "Content-Type" = "application/json" }
    return Invoke-Api -Uri $Uri -Method $Method -Headers $headers -Body $Body -Channel "xray-cloud" -ThrottleMs $ThrottleMs `
                -OnUnauthorized { Update-XrayToken | Out-Null }
}

# -------------------------------------------------------------------
# Text helpers
# -------------------------------------------------------------------
function ConvertFrom-HtmlToText {
    param([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return "" }
    $text = [System.Net.WebUtility]::HtmlDecode($Html)
    $text = $text -replace '(?i)<br\s*/?>', "`n"
    $text = $text -replace '(?i)</p>',  "`n"
    $text = $text -replace '(?i)</div>', "`n"
    $text = $text -replace '(?i)</tr>',  "`n"
    $text = $text -replace '(?i)</li>',  "`n"
    $text = $text -replace '(?i)<li[^>]*>', "- "
    $text = $text -replace '(?i)<td[^>]*>', " | "
    $text = $text -replace '(?i)<th[^>]*>', " | "
    $text = $text -replace '<[^>]+>', ''
    $text = $text -replace '(\r?\n){3,}', "`n`n"
    # Strip C0 control characters except tab (09), LF (0A), CR (0D).
    $text = $text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
    return $text.Trim()
}

# Build an ADF (Atlassian Document Format) doc from plain text.
# Returns @{ Adf = <doc>; Overflow = <string or $null> } so the caller can
# decide what to do with content beyond the size limit (we append it as a
# follow-up comment rather than silently dropping it).
function ConvertTo-AdfEx {
    param([string]$Text, [int]$MaxChars = 32000)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @{ Adf = $null; Overflow = $null } }
    $clean = $Text.Trim()
    $overflow = $null
    if ($clean.Length -gt $MaxChars) {
        $overflow = $clean.Substring($MaxChars)
        $clean    = $clean.Substring(0, $MaxChars) + "`n... [continues in a migration comment]"
    }
    $content = @()
    foreach ($line in ($clean -split "`n")) {
        $l = $line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($l)) { $content += @{ type = "paragraph"; content = @() } }
        else { $content += @{ type = "paragraph"; content = @( @{ type = "text"; text = $l } ) } }
    }
    if ($content.Count -eq 0) { return @{ Adf = $null; Overflow = $overflow } }
    return @{ Adf = @{ type = "doc"; version = 1; content = $content }; Overflow = $overflow }
}

# Back-compat thin wrapper returning just the ADF doc.
function ConvertTo-Adf {
    param([string]$Text, [int]$MaxChars = 32000)
    return (ConvertTo-AdfEx -Text $Text -MaxChars $MaxChars).Adf
}

# -------------------------------------------------------------------
# JSON file helpers (UTF-8, no BOM, deep)
# -------------------------------------------------------------------
function Save-Json {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Path, [int]$Depth = 100)
    $json = $Object | ConvertTo-Json -Depth $Depth
    $dir  = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Json {
    param([Parameter(Mandatory)][string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return $raw | ConvertFrom-Json
}

# -------------------------------------------------------------------
# Filesystem-safe filename
# -------------------------------------------------------------------
function Get-SafeFileName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $pattern = "[{0}]" -f [Regex]::Escape($invalid)
    return ($Name -replace $pattern, '_')
}

function Get-MimeType {
    param([string]$FileName)
    switch -Regex ($FileName.ToLowerInvariant()) {
        '\.png$'  { return "image/png" }
        '\.jpe?g$'{ return "image/jpeg" }
        '\.gif$'  { return "image/gif" }
        '\.bmp$'  { return "image/bmp" }
        '\.pdf$'  { return "application/pdf" }
        '\.txt$|\.log$' { return "text/plain" }
        '\.html?$'{ return "text/html" }
        '\.json$' { return "application/json" }
        '\.xml$'  { return "application/xml" }
        '\.csv$'  { return "text/csv" }
        '\.zip$'  { return "application/zip" }
        '\.docx?$'{ return "application/msword" }
        '\.xlsx?$'{ return "application/vnd.ms-excel" }
        default   { return "application/octet-stream" }
    }
}

# Sanitise a Jira Cloud label: no spaces, max 255 chars.
function Get-SafeLabel {
    param([string]$Label)
    if ([string]::IsNullOrWhiteSpace($Label)) { return $null }
    $l = ($Label -replace '\s', '_')
    if ($l.Length -gt 255) { $l = $l.Substring(0, 255) }
    return $l
}

# -------------------------------------------------------------------
# Xray Server -> Cloud test-run status mapping.
# Server native: TODO, EXECUTING, PASS, FAIL, ABORTED (+ custom)
# Cloud  native: TODO, EXECUTING, PASSED, FAILED, ABORTED (+ custom)
# (ABORTED IS a native Cloud status — do NOT collapse it to FAILED.)
# -------------------------------------------------------------------
function Convert-XrayStatus {
    param([string]$ServerStatus, [hashtable]$Overrides)
    if ([string]::IsNullOrWhiteSpace($ServerStatus)) { return "TODO" }
    $s = $ServerStatus.Trim().ToUpperInvariant()
    if ($Overrides -and $Overrides.ContainsKey($s)) { return $Overrides[$s] }
    switch ($s) {
        "PASS"      { return "PASSED" }
        "PASSED"    { return "PASSED" }
        "FAIL"      { return "FAILED" }
        "FAILED"    { return "FAILED" }
        "TODO"      { return "TODO" }
        "EXECUTING" { return "EXECUTING" }
        "ABORTED"   { return "ABORTED" }  # native Cloud status
        default     { return $s }         # custom statuses pass through; must pre-exist in Cloud.
    }
}

# -------------------------------------------------------------------
# Simple CSV-backed key map (ServerKey -> CloudKey + CloudId + Type).
# -------------------------------------------------------------------
function New-KeyMap { return [System.Collections.Generic.Dictionary[string,object]]::new() }

function Save-KeyMap {
    param([System.Collections.Generic.Dictionary[string,object]]$KeyMap, [string]$Path)
    $rows = foreach ($k in $KeyMap.Keys) {
        $v = $KeyMap[$k]
        [pscustomobject]@{ ServerKey = $k; CloudKey = $v.CloudKey; CloudId = $v.CloudId; IssueType = $v.IssueType }
    }
    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

# Append ONE mapping row immediately (crash-safe).
function Add-KeyMapRow {
    param([string]$Path, [string]$ServerKey, $Entry)
    if (-not (Test-Path $Path)) {
        Add-Content -Path $Path -Value '"ServerKey","CloudKey","CloudId","IssueType"' -Encoding UTF8
    }
    $line = '"{0}","{1}","{2}","{3}"' -f $ServerKey, $Entry.CloudKey, $Entry.CloudId, $Entry.IssueType
    Add-Content -Path $Path -Value $line -Encoding UTF8
}

function Import-KeyMap {
    param([System.Collections.Generic.Dictionary[string,object]]$KeyMap, [string]$Path)
    if (-not (Test-Path $Path)) { return }
    Import-Csv -Path $Path -Encoding UTF8 | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_.ServerKey)) {
            $KeyMap[$_.ServerKey] = [pscustomobject]@{ CloudKey = $_.CloudKey; CloudId = $_.CloudId; IssueType = $_.IssueType }
        }
    }
}

Write-Verbose "XrayMig.Common.ps1 loaded."
