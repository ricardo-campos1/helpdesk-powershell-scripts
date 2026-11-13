<#
.SYNOPSIS
    Runs the "user can't get online" checklist and suggests the likely cause.

.DESCRIPTION
    Works through the same steps I would follow by hand on a ticket where a
    user has no internet, from the PC outward:

      1. Is a network adapter connected?
      2. Does it have a real IP address? (169.254.x.x means DHCP failed)
      3. Can we ping the default gateway (the router)?
      4. Can we ping a public IP address (default 8.8.8.8)?
      5. Can we resolve a website name to an IP address (DNS)?

    At the end it prints a PASS/FAIL summary and the most likely cause, based
    on the first step that failed.

    The script only READS and tests. It does not change any network settings.

.PARAMETER PublicIP
    The internet IP address to ping. Default is 8.8.8.8 (Google public DNS).

.PARAMETER DnsName
    The name to look up in DNS. Default is www.microsoft.com.

.EXAMPLE
    .\Test-NetworkConnectivity.ps1
    Runs the full checklist with the defaults.

.EXAMPLE
    .\Test-NetworkConnectivity.ps1 -DnsName intranet.example.local
    Checks DNS against an internal name instead of a public website.

.NOTES
    Author: Ricky Campos
    Written and tested in a home lab. Runs on Windows PowerShell 5.1 and PowerShell 7.
    Some networks block ping (ICMP) to the gateway or the internet, so a failed
    ping is a strong hint, not proof. Use the result together with the other checks.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$PublicIP = '8.8.8.8',
    [string]$DnsName  = 'www.microsoft.com'
)

# ---------------------------------------------------------------------------
# Helper: ping a host a few times and return $true if any reply came back.
# Uses .NET's Ping class so it behaves the same in PowerShell 5.1 and 7.
# ---------------------------------------------------------------------------
function Test-Ping {
    param([string]$Target, [int]$Count = 2, [int]$TimeoutMs = 1500)
    $pinger = New-Object System.Net.NetworkInformation.Ping
    try {
        for ($i = 1; $i -le $Count; $i++) {
            try {
                $reply = $pinger.Send($Target, $TimeoutMs)
                if ($reply.Status -eq 'Success') { return $true }
            }
            catch {
                # An error here (no route, no permission) just counts as no reply.
            }
        }
        return $false
    }
    finally {
        $pinger.Dispose()
    }
}

# Each check adds a result here so we can print a summary at the end.
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Check, [bool]$Passed, [string]$Detail)
    $results.Add([pscustomobject]@{
        Check  = $Check
        Result = if ($Passed) { 'PASS' } else { 'FAIL' }
        Detail = $Detail
    })
    $color = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1} - {2}" -f $(if ($Passed) { 'PASS' } else { 'FAIL' }), $Check, $Detail) -ForegroundColor $color
}

Write-Host "Running network checklist on $([System.Net.Dns]::GetHostName())...`n"

# --- Step 1: adapter status -------------------------------------------------
# Same idea as Get-NetAdapter on Windows: find adapters that are connected ("Up"),
# ignoring the loopback adapter, which is always up.
$adapters = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
    Where-Object {
        $_.OperationalStatus -eq 'Up' -and
        $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback
    }

$adapterOk = [bool]$adapters
if ($adapterOk) {
    Add-Result -Check 'Adapter connected' -Passed $true -Detail (($adapters | ForEach-Object { $_.Name }) -join ', ')
}
else {
    Add-Result -Check 'Adapter connected' -Passed $false -Detail 'No network adapter is up'
}

# --- Step 2: IP address -----------------------------------------------------
# Collect IPv4 addresses and gateways from the connected adapters.
$ipAddresses = @()
$gateways    = @()
foreach ($adapter in $adapters) {
    $props = $adapter.GetIPProperties()
    $ipAddresses += $props.UnicastAddresses |
        Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } |
        ForEach-Object { $_.Address.ToString() }
    $gateways += $props.GatewayAddresses |
        Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0' } |
        ForEach-Object { $_.Address.ToString() }
}

# 169.254.x.x is APIPA: Windows gives itself this address when no DHCP server answers.
$realIPs  = @($ipAddresses | Where-Object { $_ -notlike '169.254.*' })
$apipaIPs = @($ipAddresses | Where-Object { $_ -like '169.254.*' })

if ($realIPs.Count -gt 0) {
    $ipOk = $true
    Add-Result -Check 'Valid IP address' -Passed $true -Detail ($realIPs -join ', ')
}
elseif ($apipaIPs.Count -gt 0) {
    $ipOk = $false
    Add-Result -Check 'Valid IP address' -Passed $false -Detail "APIPA address $($apipaIPs -join ', ') - DHCP did not respond"
}
else {
    $ipOk = $false
    Add-Result -Check 'Valid IP address' -Passed $false -Detail 'No IPv4 address'
}

# --- Step 3: ping the default gateway ---------------------------------------
if ($gateways.Count -gt 0) {
    $gateway   = $gateways[0]
    $gatewayOk = Test-Ping -Target $gateway
    Add-Result -Check 'Ping default gateway' -Passed $gatewayOk -Detail $gateway
}
else {
    $gatewayOk = $false
    Add-Result -Check 'Ping default gateway' -Passed $false -Detail 'No default gateway configured'
}

# --- Step 4: ping a public IP -----------------------------------------------
# Pinging an IP (not a name) tests internet access without involving DNS.
$internetOk = Test-Ping -Target $PublicIP
Add-Result -Check 'Ping public IP' -Passed $internetOk -Detail $PublicIP

# --- Step 5: DNS lookup -----------------------------------------------------
# Same idea as Resolve-DnsName or nslookup: turn a name into an IP address.
try {
    $resolved = [System.Net.Dns]::GetHostAddresses($DnsName) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        Select-Object -First 1
    $dnsOk = [bool]$resolved
    $dnsDetail = if ($dnsOk) { "$DnsName -> $resolved" } else { "$DnsName returned no IPv4 address" }
}
catch {
    $dnsOk = $false
    $dnsDetail = "$DnsName could not be resolved"
}
Add-Result -Check 'DNS lookup' -Passed $dnsOk -Detail $dnsDetail

# --- Summary and likely cause -----------------------------------------------
# The first failed step is usually where the problem is, because each step
# depends on the ones before it.
if (-not $adapterOk) {
    $likelyCause = 'No network connection at all. Check the cable or Wi-Fi, airplane mode, and whether the adapter is disabled.'
}
elseif (-not $ipOk) {
    $likelyCause = 'The PC is not getting an IP address from DHCP. Try "ipconfig /release" then "ipconfig /renew", and check the cable, switch port or Wi-Fi network. If several users are affected, check the DHCP server.'
}
elseif (-not $gatewayOk -and -not $internetOk) {
    $likelyCause = 'The PC has an IP but cannot reach the router. Check the cable or Wi-Fi signal, the switch port, and whether the IP and gateway are on the same subnet.'
}
elseif (-not $internetOk) {
    $likelyCause = 'The local network works but the internet does not. Check the router, firewall or ISP, and whether other users have the same problem.'
}
elseif (-not $dnsOk) {
    $likelyCause = 'Internet works by IP address but names do not resolve, so this is a DNS problem. Try "ipconfig /flushdns" and check which DNS servers the PC is using.'
}
elseif (-not $gatewayOk) {
    $likelyCause = 'Everything works except pinging the gateway. The router probably just blocks ping, so this is likely not a problem.'
}
else {
    $likelyCause = 'Basic connectivity looks fine. If the user still has trouble, check the specific website or app, a proxy or VPN setting, or the browser.'
}

Write-Host "`n==================== SUMMARY ===================="
foreach ($r in $results) {
    Write-Host ("{0,-22} {1}" -f $r.Check, $r.Result)
}
$passedCount = @($results | Where-Object { $_.Result -eq 'PASS' }).Count
Write-Host "`n$passedCount of $($results.Count) checks passed."
Write-Host "Likely cause: $likelyCause" -ForegroundColor Yellow
