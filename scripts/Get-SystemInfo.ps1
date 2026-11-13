<#
.SYNOPSIS
    Collects the basic facts about a PC that usually go into a help desk ticket.

.DESCRIPTION
    Gathers hostname, operating system and build, uptime, CPU, RAM, disk free
    space, IP configuration and the logged-in user, then prints a plain text
    report. The report can also be saved to a text file with -OutFile so it can
    be attached to a ticket.

    The script only READS information. It does not change anything on the PC.

    Most of the details come from CIM (Get-CimInstance), which is how Windows
    exposes hardware and OS information. If a section can't be read (for
    example when running on a non-Windows machine), that line says
    "Not available" instead of stopping the whole script.

.PARAMETER OutFile
    Optional. A path to save the report to, for example C:\Temp\PC-Info.txt.

.EXAMPLE
    .\Get-SystemInfo.ps1
    Prints the report to the console.

.EXAMPLE
    .\Get-SystemInfo.ps1 -OutFile "$env:USERPROFILE\Desktop\PC-Info.txt"
    Prints the report and also saves a copy to the desktop.

.NOTES
    Author: Ricky Campos
    Written and tested in a home lab. Runs on Windows PowerShell 5.1 and PowerShell 7.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutFile
)

# ---------------------------------------------------------------------------
# Helper: try to get a CIM class, return $null instead of an error if it fails.
# This keeps one missing piece of information from breaking the whole report.
# ---------------------------------------------------------------------------
function Get-CimSafe {
    param([string]$ClassName, [string]$Filter)
    try {
        if ($Filter) {
            Get-CimInstance -ClassName $ClassName -Filter $Filter -ErrorAction Stop
        }
        else {
            Get-CimInstance -ClassName $ClassName -ErrorAction Stop
        }
    }
    catch {
        return $null
    }
}

# The report is built up as a list of lines, then printed (and saved) at the end.
$report = New-Object System.Collections.Generic.List[string]

# --- Basic identity ---------------------------------------------------------
$hostname = [System.Net.Dns]::GetHostName()

$computerSystem = Get-CimSafe -ClassName Win32_ComputerSystem
$os             = Get-CimSafe -ClassName Win32_OperatingSystem
$cpu            = Get-CimSafe -ClassName Win32_Processor | Select-Object -First 1

# Logged-in user: Win32_ComputerSystem shows the user at the console.
# If that isn't available, fall back to the user running this script.
if ($computerSystem -and $computerSystem.UserName) {
    $loggedInUser = $computerSystem.UserName
}
else {
    $loggedInUser = "$([Environment]::UserDomainName)\$([Environment]::UserName) (user running this script)"
}

# --- Operating system and uptime --------------------------------------------
if ($os) {
    $osText = "$($os.Caption) (version $($os.Version), build $($os.BuildNumber))"

    # Uptime = now minus the last time the PC booted.
    # Long uptime is a common cause of "my PC is slow" tickets.
    $uptime     = (Get-Date) - $os.LastBootUpTime
    $uptimeText = "{0} days, {1} hours, {2} minutes (last boot {3})" -f `
        $uptime.Days, $uptime.Hours, $uptime.Minutes, $os.LastBootUpTime

    # Win32_OperatingSystem reports memory in kilobytes, so divide by 1MB to get GB.
    $totalRamGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeRamGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $ramText    = "$totalRamGB GB total, $freeRamGB GB free"
}
else {
    $osText     = "Not available ($([System.Runtime.InteropServices.RuntimeInformation]::OSDescription))"
    $uptimeText = "Not available"
    $ramText    = "Not available"
}

# --- CPU --------------------------------------------------------------------
if ($cpu) {
    $cpuText = "$($cpu.Name.Trim()) ($($cpu.NumberOfCores) cores, $($cpu.NumberOfLogicalProcessors) threads)"
}
else {
    $cpuText = "Not available ($([Environment]::ProcessorCount) logical processors)"
}

# --- Build the top of the report --------------------------------------------
$report.Add("==================== PC INFORMATION ====================")
$report.Add("Collected      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$report.Add("Hostname       : $hostname")
$report.Add("Logged-in user : $loggedInUser")
$report.Add("OS             : $osText")
$report.Add("Uptime         : $uptimeText")
$report.Add("CPU            : $cpuText")
$report.Add("RAM            : $ramText")

# --- Disks ------------------------------------------------------------------
# DriveType=3 means local fixed disks (skips USB sticks, DVD drives and network shares).
$report.Add("")
$report.Add("---- Disks ----")
$disks = Get-CimSafe -ClassName Win32_LogicalDisk -Filter "DriveType=3"
if ($disks) {
    foreach ($disk in $disks) {
        $sizeGB      = [math]::Round($disk.Size / 1GB, 1)
        $freeGB      = [math]::Round($disk.FreeSpace / 1GB, 1)
        $percentFree = if ($disk.Size -gt 0) { [math]::Round(($disk.FreeSpace / $disk.Size) * 100) } else { 0 }

        $line = "{0}  {1} GB free of {2} GB ({3}% free)" -f $disk.DeviceID, $freeGB, $sizeGB, $percentFree
        # Flag low disk space, another common cause of slowness and failed updates.
        if ($percentFree -lt 10) { $line += "  <-- LOW DISK SPACE" }
        $report.Add($line)
    }
}
else {
    # Fallback that works on any OS: .NET's DriveInfo class.
    foreach ($drive in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' -and $_.TotalSize -gt 0 }) {
        $sizeGB = [math]::Round($drive.TotalSize / 1GB, 1)
        $freeGB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        $line   = "{0}  {1} GB free of {2} GB" -f $drive.Name, $freeGB, $sizeGB
        $report.Add($line)
    }
}

# --- Network ----------------------------------------------------------------
# .NET's NetworkInterface class works on Windows PowerShell 5.1 and PowerShell 7.
# On Windows, "ipconfig /all" or Get-NetIPConfiguration show the same details.
$report.Add("")
$report.Add("---- Network (adapters that are up) ----")
$adapters = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
    Where-Object {
        $_.OperationalStatus -eq 'Up' -and
        $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback
    }

if (-not $adapters) {
    $report.Add("No connected network adapters found.")
}

foreach ($adapter in $adapters) {
    $ipProps = $adapter.GetIPProperties()

    # Only IPv4 addresses, to keep the report short and readable.
    $ipv4 = $ipProps.UnicastAddresses |
        Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } |
        ForEach-Object { $_.Address.ToString() }

    $gateways = $ipProps.GatewayAddresses |
        Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } |
        ForEach-Object { $_.Address.ToString() }

    $dnsServers = $ipProps.DnsAddresses |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        ForEach-Object { $_.ToString() }

    $report.Add("Adapter        : $($adapter.Name) ($($adapter.Description))")
    $report.Add("  IPv4 address : $(if ($ipv4) { $ipv4 -join ', ' } else { 'none' })")
    $report.Add("  Gateway      : $(if ($gateways) { $gateways -join ', ' } else { 'none' })")
    $report.Add("  DNS servers  : $(if ($dnsServers) { $dnsServers -join ', ' } else { 'none' })")

    # 169.254.x.x means the PC gave itself an address because DHCP didn't answer.
    if ($ipv4 | Where-Object { $_ -like '169.254.*' }) {
        $report.Add("  NOTE         : 169.254.x.x (APIPA) address - DHCP did not respond")
    }
}

$report.Add("=========================================================")

# --- Output -----------------------------------------------------------------
$report | ForEach-Object { Write-Output $_ }

if ($OutFile) {
    try {
        $report | Out-File -FilePath $OutFile -Encoding utf8 -ErrorAction Stop
        Write-Host "`nReport saved to $OutFile" -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not save the report to '$OutFile': $($_.Exception.Message)"
    }
}
