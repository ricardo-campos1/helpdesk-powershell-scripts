<#
.SYNOPSIS
    Resets one Active Directory user's password to a random temporary password.

.DESCRIPTION
    The classic "I forgot my password" or "I'm locked out" ticket:

      - looks up the user and shows their name and account status
      - sets a random temporary password
      - forces the user to change it at next logon
      - optionally unlocks the account with -Unlock

    The temporary password is printed to the console ONE time. It is never
    written to a file or log.

    Because this changes a real account, PowerShell asks you to confirm before
    the reset (ConfirmImpact is High). Use -WhatIf to see what would happen
    without changing anything.

    Before running this, verify the caller's identity using your
    organization's process. Resetting the wrong person's password is a
    common social engineering target.

.PARAMETER Identity
    The user's username (sAMAccountName), for example jsmith.

.PARAMETER Unlock
    Also unlock the account if it is locked out.

.EXAMPLE
    .\Reset-ADUserPassword.ps1 -Identity jsmith -WhatIf
    Shows what would happen. Nothing is changed.

.EXAMPLE
    .\Reset-ADUserPassword.ps1 -Identity jsmith -Unlock
    Resets the password, unlocks the account and asks for confirmation first.

.NOTES
    Author: Ricky Campos
    Written and tested in a home lab, not used in production.
    Requires the ActiveDirectory module (RSAT) and an account allowed to reset passwords.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$Identity,

    [switch]$Unlock
)

# ---------------------------------------------------------------------------
# Step 0: make sure the ActiveDirectory module is installed.
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Warning 'The ActiveDirectory module is not installed. Install RSAT (Active Directory tools) and try again.'
    exit 1
}
Import-Module ActiveDirectory -ErrorAction Stop

# ---------------------------------------------------------------------------
# Helper: generate a random temporary password.
# Same approach as New-ADUserFromCsv.ps1: cryptographic randomness, no
# look-alike characters, and at least one of each character type.
# ---------------------------------------------------------------------------
function New-TempPassword {
    param([int]$Length = 14)

    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnpqrstuvwxyz'
    $digits  = '23456789'
    $symbols = '!@#$%*?'
    $all     = $upper + $lower + $digits + $symbols

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    $pick = {
        param([string]$Set)
        $bytes = New-Object byte[] 4
        $rng.GetBytes($bytes)
        $Set[[BitConverter]::ToUInt32($bytes, 0) % $Set.Length]
    }

    $chars = @(
        (& $pick $upper), (& $pick $lower), (& $pick $digits), (& $pick $symbols)
    )
    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars += (& $pick $all)
    }
    $rng.Dispose()

    -join ($chars | Get-Random -Count $chars.Count)
}

# ---------------------------------------------------------------------------
# Step 1: find the user and show who we are about to change.
# ---------------------------------------------------------------------------
try {
    $user = Get-ADUser -Identity $Identity -Properties DisplayName, LockedOut, Enabled -ErrorAction Stop
}
catch {
    Write-Warning "User '$Identity' was not found in Active Directory."
    exit 1
}

Write-Host "User       : $($user.DisplayName) ($($user.SamAccountName))"
Write-Host "Enabled    : $($user.Enabled)"
Write-Host "Locked out : $($user.LockedOut)"

if (-not $user.Enabled) {
    # A disabled account usually means the person left or is on leave.
    # That needs a different process than a password reset, so stop here.
    Write-Warning 'This account is disabled. Check with a supervisor before enabling or resetting it.'
    exit 1
}

# ---------------------------------------------------------------------------
# Step 2: reset the password (and unlock if asked).
# ShouldProcess handles -WhatIf and the confirmation prompt.
# ---------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess("$($user.SamAccountName) ($($user.DisplayName))", 'Reset password and require change at next logon')) {
    try {
        $tempPassword = New-TempPassword
        $securePassword = ConvertTo-SecureString -String $tempPassword -AsPlainText -Force

        Set-ADAccountPassword -Identity $user -Reset -NewPassword $securePassword -ErrorAction Stop
        Set-ADUser -Identity $user -ChangePasswordAtLogon $true -ErrorAction Stop

        if ($Unlock) {
            if ($user.LockedOut) {
                Unlock-ADAccount -Identity $user -ErrorAction Stop
                Write-Host 'Account unlocked.' -ForegroundColor Green
            }
            else {
                Write-Host 'Account was not locked, so no unlock was needed.'
            }
        }

        Write-Host "`nPassword reset for $($user.SamAccountName). They must change it at next logon." -ForegroundColor Green
        # Write-Host shows the password on screen without sending it down the
        # pipeline, so it doesn't end up in a variable or a redirected file by accident.
        Write-Host "Temporary password (shown once, not saved): $tempPassword" -ForegroundColor Yellow
    }
    catch {
        Write-Warning "Password reset failed: $($_.Exception.Message)"
        exit 1
    }
}
