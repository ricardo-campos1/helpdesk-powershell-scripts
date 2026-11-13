<#
.SYNOPSIS
    Creates Active Directory user accounts from a CSV file (new hire onboarding).

.DESCRIPTION
    Reads a CSV with the columns FirstName, LastName, Department and Title, and
    for each row:

      - builds a username (first initial + last name, for example jsmith)
        and adds a number if that name is already taken (jsmith2)
      - creates the user in the OU you pass with -OU
      - sets a random temporary password
      - requires the user to change the password at first logon

    Every row is logged to a results CSV (Created, WhatIf, Skipped or Failed).
    Temporary passwords are shown on screen once and are never written to the log.

    Run it with -WhatIf first. That shows what WOULD be created without
    changing anything in Active Directory.

.PARAMETER CsvPath
    Path to the input CSV. See samples\new_users.csv for the format.

.PARAMETER OU
    Distinguished name of the OU to create the users in,
    for example "OU=New Hires,DC=example,DC=local".

.PARAMETER Domain
    The domain used for the user principal name (jsmith@example.local).
    Default is example.local.

.PARAMETER LogPath
    Where to save the results CSV. Default is NewUserResults_<date-time>.csv
    in the current folder.

.EXAMPLE
    .\New-ADUserFromCsv.ps1 -CsvPath ..\samples\new_users.csv -OU "OU=New Hires,DC=example,DC=local" -WhatIf
    Dry run: shows what would be created. Nothing is changed.

.EXAMPLE
    .\New-ADUserFromCsv.ps1 -CsvPath ..\samples\new_users.csv -OU "OU=New Hires,DC=example,DC=local"
    Creates the users for real and writes a results log.

.NOTES
    Author: Ricky Campos
    Written and tested in a home lab, not used in production.
    Requires the ActiveDirectory module (RSAT) and an account allowed to create users in that OU.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $true)]
    [string]$OU,

    [string]$Domain = 'example.local',

    [string]$LogPath = ".\NewUserResults_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

# ---------------------------------------------------------------------------
# Step 0: make sure the ActiveDirectory module is installed before doing anything.
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Warning 'The ActiveDirectory module is not installed. Install RSAT (Active Directory tools) and try again.'
    exit 1
}
Import-Module ActiveDirectory -ErrorAction Stop

# ---------------------------------------------------------------------------
# Helper: generate a random temporary password.
# Uses a cryptographic random number generator (not Get-Random) and leaves out
# characters that are easy to mix up when read aloud (0/O, 1/l/I).
# Always includes at least one uppercase, lowercase, number and symbol so it
# meets the default AD complexity rules.
# ---------------------------------------------------------------------------
function New-TempPassword {
    param([int]$Length = 14)

    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnpqrstuvwxyz'
    $digits  = '23456789'
    $symbols = '!@#$%*?'
    $all     = $upper + $lower + $digits + $symbols

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    # Picks one random character from a set of characters.
    $pick = {
        param([string]$Set)
        $bytes = New-Object byte[] 4
        $rng.GetBytes($bytes)
        $Set[[BitConverter]::ToUInt32($bytes, 0) % $Set.Length]
    }

    # One from each required group, then fill the rest from all characters.
    $chars = @(
        (& $pick $upper), (& $pick $lower), (& $pick $digits), (& $pick $symbols)
    )
    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars += (& $pick $all)
    }
    $rng.Dispose()

    # Shuffle so the required characters are not always in the first four spots.
    -join ($chars | Get-Random -Count $chars.Count)
}

# ---------------------------------------------------------------------------
# Helper: build a unique username (sAMAccountName) like jsmith, jsmith2, jsmith3.
# $Reserved holds names already used earlier in this run, so two people with
# the same name in one CSV don't collide (important during -WhatIf, when
# nothing is actually created yet).
# ---------------------------------------------------------------------------
function Get-UniqueUsername {
    param([string]$FirstName, [string]$LastName, [System.Collections.Generic.HashSet[string]]$Reserved)

    # Keep letters only and lowercase them (O'Brien -> obrien).
    $first = ($FirstName -replace '[^a-zA-Z]', '').ToLower()
    $last  = ($LastName  -replace '[^a-zA-Z]', '').ToLower()
    $base  = $first.Substring(0, 1) + $last

    # sAMAccountName has a 20 character limit. Leave room for a number on the end.
    if ($base.Length -gt 18) { $base = $base.Substring(0, 18) }

    $candidate = $base
    $number    = 2
    while ($Reserved.Contains($candidate) -or (Get-ADUser -Filter "SamAccountName -eq '$candidate'")) {
        $candidate = "$base$number"
        $number++
    }
    [void]$Reserved.Add($candidate)
    return $candidate
}

# ---------------------------------------------------------------------------
# Step 1: check the inputs.
# ---------------------------------------------------------------------------
if (-not (Test-Path -Path $CsvPath)) {
    Write-Warning "CSV file not found: $CsvPath"
    exit 1
}

$users = @(Import-Csv -Path $CsvPath)
if ($users.Count -eq 0) {
    Write-Warning 'The CSV file has no rows.'
    exit 1
}

$requiredColumns = 'FirstName', 'LastName', 'Department', 'Title'
$missingColumns  = $requiredColumns | Where-Object { $users[0].PSObject.Properties.Name -notcontains $_ }
if ($missingColumns) {
    Write-Warning "The CSV is missing these columns: $($missingColumns -join ', ')"
    exit 1
}

try {
    Get-ADOrganizationalUnit -Identity $OU -ErrorAction Stop | Out-Null
}
catch {
    Write-Warning "OU not found: $OU"
    exit 1
}

# ---------------------------------------------------------------------------
# Step 2: create each user.
# ---------------------------------------------------------------------------
$log           = New-Object System.Collections.Generic.List[object]
$reservedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$newPasswords  = New-Object System.Collections.Generic.List[object]   # shown on screen only

foreach ($row in $users) {
    $firstName = "$($row.FirstName)".Trim()
    $lastName  = "$($row.LastName)".Trim()

    # One log entry per row. Status and Message get filled in below.
    $entry = [ordered]@{
        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        FirstName      = $firstName
        LastName       = $lastName
        SamAccountName = ''
        UPN            = ''
        Department     = $row.Department
        Title          = $row.Title
        Status         = ''
        Message        = ''
    }

    # Skip rows with no usable first or last name.
    if (($firstName -replace '[^a-zA-Z]', '') -eq '' -or ($lastName -replace '[^a-zA-Z]', '') -eq '') {
        $entry.Status  = 'Skipped'
        $entry.Message = 'FirstName or LastName is empty'
        $log.Add([pscustomobject]$entry)
        continue
    }

    try {
        $username = Get-UniqueUsername -FirstName $firstName -LastName $lastName -Reserved $reservedNames
        $upn      = "$username@$Domain"
        $entry.SamAccountName = $username
        $entry.UPN            = $upn

        # ShouldProcess is what makes -WhatIf and -Confirm work.
        # With -WhatIf it prints "What if: ..." and returns $false, so nothing is created.
        if ($PSCmdlet.ShouldProcess("$username ($firstName $lastName) in $OU", 'Create AD user')) {
            $tempPassword = New-TempPassword

            $params = @{
                Name                  = "$firstName $lastName"
                GivenName             = $firstName
                Surname               = $lastName
                DisplayName           = "$firstName $lastName"
                SamAccountName        = $username
                UserPrincipalName     = $upn
                Department            = $row.Department
                Title                 = $row.Title
                Path                  = $OU
                AccountPassword       = (ConvertTo-SecureString -String $tempPassword -AsPlainText -Force)
                ChangePasswordAtLogon = $true
                Enabled               = $true
                ErrorAction           = 'Stop'
            }
            New-ADUser @params

            $entry.Status  = 'Created'
            $entry.Message = 'Must change password at next logon'
            $newPasswords.Add([pscustomobject]@{ Username = $username; TempPassword = $tempPassword })
        }
        else {
            $entry.Status  = 'WhatIf'
            $entry.Message = 'Not created (dry run)'
        }
    }
    catch {
        $entry.Status  = 'Failed'
        $entry.Message = $_.Exception.Message
    }

    $log.Add([pscustomobject]$entry)
}

# ---------------------------------------------------------------------------
# Step 3: report the results.
# ---------------------------------------------------------------------------
# The log never includes passwords. Export-Csv is skipped during -WhatIf so a
# dry run leaves no files behind.
$log | Format-Table SamAccountName, FirstName, LastName, Status, Message -AutoSize

if (-not $WhatIfPreference) {
    $exportParams = @{ Path = $LogPath }
    # Windows PowerShell 5.1 adds a "#TYPE" line to the top of the CSV unless told
    # not to. PowerShell 7 doesn't, and warns that the switch is obsolete.
    if ($PSVersionTable.PSVersion.Major -lt 6) { $exportParams.NoTypeInformation = $true }
    $log | Export-Csv @exportParams
    Write-Host "Results saved to $LogPath"
}

if ($newPasswords.Count -gt 0) {
    Write-Host "`nTemporary passwords (shown once, not saved anywhere). Give them to each user securely:" -ForegroundColor Yellow
    foreach ($item in $newPasswords) {
        Write-Host ("  {0,-20} {1}" -f $item.Username, $item.TempPassword)
    }
}
