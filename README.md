# Help Desk PowerShell Scripts

A small set of PowerShell scripts for common help desk tasks: gathering PC details for a ticket, troubleshooting a user who can't get online, onboarding new users in Active Directory, and resetting a password.

I built these to practice PowerShell while preparing for help desk and IT support roles. They were written and tested in a lab, not in a production environment.

## Scripts

| Script | Help desk task |
| --- | --- |
| `scripts/Get-SystemInfo.ps1` | "What are the specs on this PC?" Collects the basics for a ticket. |
| `scripts/Test-NetworkConnectivity.ps1` | "I can't get online." Runs the troubleshooting checklist. |
| `scripts/New-ADUserFromCsv.ps1` | New hire onboarding. Creates AD accounts from a CSV. |
| `scripts/Reset-ADUserPassword.ps1` | "I forgot my password" or "I'm locked out." |

### Get-SystemInfo.ps1

Prints a plain report with the hostname, logged-in user, OS and build, uptime, CPU, RAM, disk free space and IP configuration (address, gateway, DNS servers). It flags disks under 10% free and 169.254.x.x addresses. With `-OutFile` it also saves the report to a text file so it can be attached to a ticket. It only reads information and changes nothing.

### Test-NetworkConnectivity.ps1

Works through the same steps I'd follow by hand, from the PC outward:

1. Is a network adapter connected?
2. Does it have a real IP address, or a 169.254.x.x (APIPA) address because DHCP didn't answer?
3. Can it ping the default gateway?
4. Can it ping a public IP (8.8.8.8 by default)?
5. Can it resolve a name in DNS (www.microsoft.com by default)?

It prints PASS or FAIL for each step and a likely cause based on the first step that failed. It changes no settings. Some networks block ping, so a failed ping is a hint rather than proof.

### New-ADUserFromCsv.ps1

Reads a CSV with `FirstName`, `LastName`, `Department` and `Title` and creates a user for each row in the OU you choose. It:

- builds a username from first initial and last name (`javery`), adding a number if it's taken (`javery2`)
- sets a random temporary password and requires a change at first logon
- logs each row to a results CSV as Created, WhatIf, Skipped or Failed
- supports `-WhatIf` for a dry run

Temporary passwords are shown on screen once and are not written to the log. A sample input file is in `samples/new_users.csv` (fake names).

### Reset-ADUserPassword.ps1

Looks up one user, shows their name and whether the account is enabled or locked, then resets the password to a random temporary one and requires a change at next logon. `-Unlock` also unlocks the account. It asks for confirmation before making the change, and stops if the account is disabled. The temporary password is printed once and never saved.

## How to run

Open PowerShell in the repo folder. If scripts are blocked by execution policy, you can allow them for the current window only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Gather PC info, and optionally save it:

```powershell
.\scripts\Get-SystemInfo.ps1
.\scripts\Get-SystemInfo.ps1 -OutFile "$env:USERPROFILE\Desktop\PC-Info.txt"
```

Run the network checklist:

```powershell
.\scripts\Test-NetworkConnectivity.ps1
.\scripts\Test-NetworkConnectivity.ps1 -DnsName intranet.example.local
```

Create users. Always do a dry run with `-WhatIf` first:

```powershell
.\scripts\New-ADUserFromCsv.ps1 -CsvPath .\samples\new_users.csv -OU "OU=New Hires,DC=example,DC=local" -WhatIf
.\scripts\New-ADUserFromCsv.ps1 -CsvPath .\samples\new_users.csv -OU "OU=New Hires,DC=example,DC=local"
```

Reset a password:

```powershell
.\scripts\Reset-ADUserPassword.ps1 -Identity javery -WhatIf
.\scripts\Reset-ADUserPassword.ps1 -Identity javery -Unlock
```

Each script has built-in help:

```powershell
Get-Help .\scripts\New-ADUserFromCsv.ps1 -Full
```

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- For the two AD scripts: the ActiveDirectory module (part of RSAT) and an account with rights to create users or reset passwords. The scripts check for the module and exit with a message if it's missing.

## Safety notes

- `Get-SystemInfo.ps1` and `Test-NetworkConnectivity.ps1` only read and test. They don't change anything.
- Both AD scripts support `-WhatIf`, so you can see exactly what would happen before anything changes.
- `Reset-ADUserPassword.ps1` asks for confirmation before resetting and refuses to touch disabled accounts.
- Temporary passwords come from a cryptographic random generator, skip look-alike characters (0/O, 1/l/I), and are only shown on screen. They're never written to a file or log.
- Verify a caller's identity before resetting a password. Password reset requests are a common social engineering target.
- There are no real credentials, domains or user data in this repo. The sample users and `example.local` domain are made up.

## What I learned

- Using `SupportsShouldProcess` so a script gets `-WhatIf` and `-Confirm` for free, and why that matters before touching real accounts.
- Pulling system details from CIM classes like `Win32_OperatingSystem` and `Win32_LogicalDisk` instead of clicking through several windows.
- Turning a troubleshooting checklist into code made me think about the order of the steps: each one depends on the one before it, so the first failure usually points to the cause.
- Handling errors with `try`/`catch` so one bad CSV row or missing value doesn't stop the whole run.
- Keeping secrets out of logs and files, even in a lab.
