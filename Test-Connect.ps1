# ===================================================================
# Test-Connect.ps1 — standalone connectivity probe (NO dependencies).
# Replicates the old working scripts' pattern and tries each strategy
# against both candidate source hosts, failing fast. Tells you exactly
# which combination connects so we can bake it into the toolkit.
# ===================================================================

[CmdletBinding()]
param(
    [string[]]$Hosts = @(
        "https://dta-jira.jpadc.corpintra.net/jira",       # Production
        "https://dta-jira-qa.jpn.dc.tbintra.net/jira"      # QA
    )
)

# --- Legacy cert bypass, exactly like the old working scripts (PS 5.1) ---
if ($PSVersionTable.PSVersion.Major -lt 6) {
    if (-not ("TrustAllCertsPolicy" -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}
try { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } } catch {}

# --- Credentials (once) ---
$u = Read-Host "Jira Server Username"
$sp = Read-Host "Jira Server Password" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp)
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
$auth = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}:{1}" -f $u, $pw)))
$pw = $null
$headers = @{ Authorization = $auth; Accept = "application/json" }

$sysProxy = $null
try { $sysProxy = [System.Net.WebRequest]::GetSystemWebProxy() } catch {}

# strategy = TLS setting + proxy choice. Ordered: old-script equivalent first.
$strategies = @(
    @{ Name = "SystemDefault TLS + system proxy"; Tls = "SystemDefault"; Proxy = "system" },
    @{ Name = "SystemDefault TLS + DIRECT";       Tls = "SystemDefault"; Proxy = "direct" },
    @{ Name = "Tls12 + system proxy";             Tls = "Tls12";         Proxy = "system" },
    @{ Name = "Tls12+Tls13 + system proxy";       Tls = "Tls12Tls13";    Proxy = "system" },
    @{ Name = "Tls12 + DIRECT";                   Tls = "Tls12";         Proxy = "direct" }
)

function Set-Tls { param($mode)
    try {
        switch ($mode) {
            "SystemDefault" { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::SystemDefault }
            "Tls12"         { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
            "Tls12Tls13"    { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
        }
    } catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
}

foreach ($h in $Hosts) {
    $hostName = ([uri]$h).Host
    Write-Host ""
    Write-Host "=== $h ===" -ForegroundColor Cyan

    # DNS first (fast)
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($hostName)
        Write-Host ("  DNS OK: " + (($ips | ForEach-Object { $_.IPAddressToString }) -join ', ')) -ForegroundColor Green
    } catch {
        Write-Host "  DNS FAIL: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  -> This host is not resolvable from this machine (proxy/VPN needed). Skipping." -ForegroundColor Yellow
        continue
    }

    $won = $false
    foreach ($s in $strategies) {
        Set-Tls $s.Tls
        if ($s.Proxy -eq "direct") { [System.Net.WebRequest]::DefaultWebProxy = $null }
        else { [System.Net.WebRequest]::DefaultWebProxy = $sysProxy }
        try {
            $r = Invoke-RestMethod -Uri "$h/rest/api/2/myself" -Headers $headers -Method Get -TimeoutSec 25 -ErrorAction Stop
            Write-Host ("  WIN  [{0}] -> {1} ({2})" -f $s.Name, $r.displayName, $r.name) -ForegroundColor Green
            $won = $true
            break
        } catch {
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode.value__ } catch {}
            $msg = $_.Exception.Message
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message }
            Write-Host ("  fail [{0}] (HTTP {1}): {2}" -f $s.Name, $code, ($msg -replace '\s+',' ')) -ForegroundColor DarkYellow
        }
    }
    if (-not $won) { Write-Host "  No strategy connected to this host." -ForegroundColor Red }
}

Write-Host ""
Write-Host "Done. Tell me which line says WIN (host + strategy)." -ForegroundColor Cyan
