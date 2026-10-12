<#
.SYNOPSIS
    Makes a Windows Veeam Backup & Replication (VBR) server match the svc_veeam and
    PostgreSQL Windows-authentication standard.

.DESCRIPTION
    Runs from RMM as SYSTEM, with no prompts, under Windows PowerShell 5.1 (64-bit).

    The standard:
      1. A local account svc_veeam exists and is a member of local Administrators.
         Its password never expires, the user cannot change it, and the account
         never expires.
      2. The VBR configuration database (PostgreSQL) uses Windows authentication
         (SSPI). No password login to PostgreSQL is possible.
      3. pg_ident.conf maps only SYSTEM, svc_veeam and the accounts that Veeam
         services run as, to the postgres role.

    Default mode is AUDIT: the script reads and reports, and changes nothing.

    The switch to Windows authentication edits the VBR registry directly. Veeam
    does not support this method. A full conversion stops every Veeam service,
    including vPower NFS: run -Apply in a maintenance window, with an RMM script
    timeout of 45 minutes or more.

.PARAMETER Apply
    Fix every item that is not standard, except a missing svc_veeam account.

.PARAMETER CreateServiceAccount
    Create svc_veeam when it is missing. The password comes only from the
    environment variable VEEAM_SVC_PASSWORD (an RMM secure variable). Runs alone
    (create the account, then audit the rest) or together with -Apply.

.PARAMETER WorkRoot
    Work folder for logs, run folders and the changes-in-progress marker.
    Default C:\ProgramData\VeeamStandardise. Only SYSTEM and Administrators can
    read it.

.NOTES
    EXIT CODES (for your RMM):
      0  OK            - the server matches the standard, or the script fixed
                         every item
      5  ACTION_NEEDED - soft error: AUDIT found drift, or a fix needs a person
                         or a flag. ActionRequired says what to do
      10 RETRY         - another run holds the lock, a job is running, or a
                         service did not stop before any change. Try again later
      11 UNSUPPORTED   - the server is outside the scope of this script, or its
                         PostgreSQL setup is not one the script can edit safely
      20 PREFLIGHT     - wrong PowerShell, not elevated, 32-bit host, Constrained
                         Language Mode, VBR or PostgreSQL not found, or the
                         WorkRoot is not safe
      40 ESCALATE      - a change failed. The script restored the server and
                         checked that VBR works. PAGE AN OPERATOR
      50 ESCALATE_NOW  - a change failed and the restore also failed, or a marker
                         from an unfinished run exists. VBR may be down.
                         PAGE AN OPERATOR NOW

    When a run finds more than one issue, the highest exit code wins.
    This script and Update-VeeamPostgres.ps1 share the Global\VeeamPgUpdate mutex,
    so they never run at the same time.
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [switch] $CreateServiceAccount,
    [string] $WorkRoot = 'C:\ProgramData\VeeamStandardise'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

#region Core
# ===========================================================================
#  BUILT-IN SETTINGS  -  EDIT THESE, THEN RE-UPLOAD THIS ONE FILE TO YOUR RMM
#
#  ServiceAccountName         local maintenance account mapped in pg_ident.conf
#  ServiceAccountDescription  its description (48 characters or fewer)
#  PasswordEnvVar             environment variable that RMM fills from a secure
#                             variable; read once, then removed from the process
#  ServiceStopTimeoutSec      limit for stopping all Veeam services, and again
#                             for starting them
#  VbrConnectTimeoutSec       limit for the VBR connect check after a change
#  RollbackSettleSec          how long VeeamBackupSvc must stay running after a
#                             rollback
#  BusyPersistentHours        a busy Veeam process older than this is treated as
#                             a persistent job (log backup, CDP)
#  RetentionDays              how long to keep logs and run folders
#
#  External settings files are not supported: edit this block and redeploy.
# ===========================================================================
function Get-DefaultConfig {
    return @{
        ServiceAccountName        = 'svc_veeam'
        ServiceAccountDescription = 'Veeam maintenance account (PostgreSQL SSPI map)'
        PasswordEnvVar            = 'VEEAM_SVC_PASSWORD'
        ServiceStopTimeoutSec     = 300
        VbrConnectTimeoutSec      = 600
        RollbackSettleSec         = 300
        BusyPersistentHours       = 6
        RetentionDays             = 30
    }
}

# Exit codes (spec 6.2): the same numbers and names as Update-VeeamPostgres.ps1.
function Get-ExitCodeTable {
    return @{
        OK            = 0
        ACTION_NEEDED = 5
        RETRY         = 10
        UNSUPPORTED   = 11
        PREFLIGHT     = 20
        ESCALATE      = 40
        ESCALATE_NOW  = 50
    }
}

# Levelled console logging; the transcript captures it. Copied from the updater.
# An empty message is allowed, so logging an empty stderr can never stop the run.
# The time uses the invariant culture so the separator is always ':'.
function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string] $Level = 'INFO'
    )
    $time = (Get-Date).ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    $line = '{0} [{1,-5}] {2}' -f $time, $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'STEP'  { Write-Host ''; Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

# Collapse whitespace and cap the length for the one-line RMM summary. The full
# text stays in the transcript. The result is never longer than MaxLength; a cut
# text ends with three dots.
function Format-ShortText {
    param(
        [string] $Text = '',
        [int] $MaxLength = 900
    )
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $flat = ($Text -replace '\s+', ' ').Trim()
    if ($flat.Length -le $MaxLength) { return $flat }
    if ($MaxLength -le 3) { return $flat.Substring(0, [Math]::Max(0, $MaxLength)) }
    return $flat.Substring(0, $MaxLength - 3) + '...'
}

# Runs an external program and returns { ExitCode; StdOut; StdErr }. Errors come
# back as values and are never thrown: Windows PowerShell 5.1 turns native stderr
# into a terminating error under $ErrorActionPreference = 'Stop', so the preference
# is relaxed for this call only, and stderr lines are told apart from stdout lines
# by type (ErrorRecord). StdinText is piped to the program's stdin; Windows
# PowerShell 5.1 pipes it as ASCII, so send ASCII only. A program that cannot be
# started gives ExitCode -1 and the reason in StdErr.
# This function logs nothing. Never log the arguments of a call that carries a secret.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $Arguments = @(),
        [string] $StdinText
    )
    if ($null -eq $Arguments) { $Arguments = @() }
    $useStdin = $PSBoundParameters.ContainsKey('StdinText')
    $outLines = New-Object System.Collections.ArrayList
    $errLines = New-Object System.Collections.ArrayList
    $code = -1
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($useStdin) {
            $all = $StdinText | & $FilePath @Arguments 2>&1
        } else {
            $all = & $FilePath @Arguments 2>&1
        }
        $code = $LASTEXITCODE
        foreach ($item in @($all)) {
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                [void]$errLines.Add([string]$item.Exception.Message)
            } elseif ($null -ne $item) {
                [void]$outLines.Add([string]$item)
            }
        }
    } catch {
        $code = -1
        [void]$errLines.Add(("Could not run '{0}': {1}" -f $FilePath, $_.Exception.Message))
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($null -eq $code) { $code = -1 }
    return [pscustomobject]@{
        ExitCode = [int]$code
        StdOut   = ([string]::Join("`r`n", [string[]]$outLines.ToArray())).Trim()
        StdErr   = ([string]::Join("`r`n", [string[]]$errLines.ToArray())).Trim()
    }
}

# Reads one registry value quietly: $null when the key or the value is missing.
# Uses the key's GetValue, so a missing value never writes an error record into
# the transcript. Copied from the updater (parameter renamed to -Path).
function Get-RegValue {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Name
    )
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $null }
        return $item.GetValue($Name)
    } catch {
        return $null
    }
}

# StrictMode-safe read of a hashtable key or an object property, with a default.
# A dictionary is read by key only (so 'Count' is not a key of a hashtable).
# An array value comes back unrolled, like any PowerShell output: wrap the call
# in @() when a list is expected.
function Get-CfgValue {
    param(
        $Object,
        [Parameter(Mandatory)][string] $Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    try {
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    } catch {
        return $Default
    }
    return $Default
}

# Parses a JSON array into a flat list, the same way on both PowerShell editions.
# Windows PowerShell 5.1's ConvertFrom-Json emits a whole array as ONE object;
# PowerShell 7 enumerates it. Copied from the updater. Empty text and JSON null
# (json_agg over no rows) give an empty result, and null items are dropped.
# Wrap the call in @() to get an array.
function ConvertFrom-JsonArrayText {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $parsed = $Text | ConvertFrom-Json -ErrorAction Stop
    $items = New-Object System.Collections.ArrayList
    foreach ($entry in @($parsed)) {
        if ($null -eq $entry) { continue }
        if ($entry -isnot [string] -and $entry -is [System.Collections.IEnumerable]) {
            foreach ($inner in $entry) {
                if ($null -ne $inner) { [void]$items.Add($inner) }
            }
        } else {
            [void]$items.Add($entry)
        }
    }
    return $items.ToArray()
}

# Writes text as UTF-8 without a BOM to a temp file in the same folder, then swaps
# it in, so a reader never sees a half-written file. For JSON state in the
# WorkRoot only: pg_hba.conf and pg_ident.conf use Write-ConfFileAtomic.
# File.Replace gets [NullString]::Value for "no backup file": PowerShell passes a
# plain $null to a .NET string parameter as '', which File.Replace rejects, and
# every replace would then fall back to the delete-and-move of Move-Item -Force.
function Write-AtomicText {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text
    )
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if ($parent -and -not [System.IO.Directory]::Exists($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    $tmp = '{0}.tmp.{1}.{2}' -f $fullPath, $PID, [guid]::NewGuid().ToString('N')
    try {
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($tmp, $Text, $encoding)
        if ([System.IO.File]::Exists($fullPath)) {
            try {
                [System.IO.File]::Replace($tmp, $fullPath, [NullString]::Value, $true)
            } catch {
                Move-Item -LiteralPath $tmp -Destination $fullPath -Force -ErrorAction Stop
            }
        } else {
            Move-Item -LiteralPath $tmp -Destination $fullPath -Force -ErrorAction Stop
        }
    } finally {
        if ([System.IO.File]::Exists($tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# ConvertTo-Json -Depth 8, then Write-AtomicText (UTF-8, no BOM).
function Write-AtomicJson {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowNull()] $Object
    )
    $json = ConvertTo-Json -InputObject $Object -Depth 8
    Write-AtomicText -Path $Path -Text $json
}
#endregion Core

#region Outcome
# The RMM report (spec 6.4). Its key order is the order of the fields on the
# summary line. Status fields start as UNKNOWN and text fields as ''.
function New-RunReport {
    param([Parameter(Mandatory)][string] $Mode)
    return [ordered]@{
        Computer       = $env:COMPUTERNAME
        Timestamp      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK', [System.Globalization.CultureInfo]::InvariantCulture)
        Mode           = $Mode
        VbrVersion     = ''
        PgMajor        = ''
        SvcAccount     = 'UNKNOWN'
        DbAuth         = 'UNKNOWN'
        PgHba          = 'UNKNOWN'
        PgIdent        = 'UNKNOWN'
        PgPassword     = 'UNKNOWN'
        Stage          = 'UNTOUCHED'
        Outcome        = 'UNKNOWN'
        ExitCode       = ''
        IssueCode      = ''
        ActionRequired = ''
        Detail         = ''
        LogPath        = ''
    }
}

# Records one issue for this run in $script:Issues (an ArrayList, created when
# missing). Every check reports here; Complete-Run picks the exit code from the
# whole list (spec 6.2).
function Add-RunIssue {
    param(
        [Parameter(Mandatory)][string] $Code,
        [Parameter(Mandatory)][int] $ExitCode,
        [string] $Detail = '',
        [string] $Action = ''
    )
    $list = Get-Variable -Name Issues -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if (-not ($list -is [System.Collections.ArrayList])) {
        $newList = New-Object System.Collections.ArrayList
        if ($null -ne $list) {
            foreach ($oldIssue in @($list)) {
                if ($null -ne $oldIssue) { [void]$newList.Add($oldIssue) }
            }
        }
        $script:Issues = $newList
        $list = $newList
    }
    [void]$list.Add([pscustomobject]@{
        Code     = $Code
        ExitCode = $ExitCode
        Detail   = $Detail
        Action   = $Action
    })
    $level = 'WARN'
    if ($ExitCode -ge 40) { $level = 'ERROR' }
    Write-Log ('Issue {0} (exit {1}): {2}' -f $Code, $ExitCode, $Detail) $level
}

# Default ActionRequired text for each exit code (spec 6.2).
function Get-RmmActionForExitCode {
    param([Parameter(Mandatory)][int] $ExitCode)
    switch ($ExitCode) {
        0  { return 'None' }
        5  { return 'Read Detail. Fix the drift by re-running with -Apply, or do what the issue asks, then re-run.' }
        10 { return 'Retry this script later.' }
        11 { return 'This server is outside the scope of this script. Handle it by hand.' }
        20 { return 'Fix the preflight failure in Detail, then re-run.' }
        40 { return 'PAGE AN OPERATOR. A change failed and the script restored the server. Read Detail and the run folder before any re-run.' }
        50 { return 'PAGE AN OPERATOR NOW. VBR may be down. Follow the manual recovery steps in the README.' }
        default { return 'Investigate the undocumented exit code.' }
    }
}

# Picks the run result from all issues: the highest ExitCode wins, and on a tie the
# earliest issue wins. Detail lists every issue as 'CODE: detail' (just 'CODE' when
# the issue has no detail), joined by ' | '. Issues may be objects or hashtables.
function Resolve-RunOutcome {
    param([AllowNull()][AllowEmptyCollection()][object[]] $Issues = @())
    $winner = $null
    $winnerCode = -1
    $parts = New-Object System.Collections.ArrayList
    foreach ($issue in @($Issues)) {
        if ($null -eq $issue) { continue }
        $code = [string](Get-CfgValue -Object $issue -Name 'Code' -Default '')
        $exitCode = [int](Get-CfgValue -Object $issue -Name 'ExitCode' -Default 0)
        $detail = [string](Get-CfgValue -Object $issue -Name 'Detail' -Default '')
        if ($detail) { [void]$parts.Add(('{0}: {1}' -f $code, $detail)) } else { [void]$parts.Add($code) }
        if ($exitCode -gt $winnerCode) {
            $winner = $issue
            $winnerCode = $exitCode
        }
    }
    if ($null -eq $winner) {
        return [pscustomobject]@{ ExitCode = 0; IssueCode = ''; ActionRequired = 'None'; Detail = '' }
    }
    $action = [string](Get-CfgValue -Object $winner -Name 'Action' -Default '')
    if (-not $action) { $action = Get-RmmActionForExitCode -ExitCode $winnerCode }
    return [pscustomobject]@{
        ExitCode       = $winnerCode
        IssueCode      = [string](Get-CfgValue -Object $winner -Name 'Code' -Default '')
        ActionRequired = $action
        Detail         = ($parts.ToArray() -join ' | ')
    }
}

# The RMM summary block (the updater's format): a header, one 'Key=Value; Key=Value' line
# with every report field, the action and issue lines when they apply, a footer.
function Format-RmmSummary {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Report)
    $pairs = New-Object System.Collections.ArrayList
    foreach ($key in @($Report.Keys)) {
        [void]$pairs.Add(('{0}={1}' -f $key, (Format-ShortText -Text ([string]$Report[$key]))))
    }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('=== RMM SUMMARY ===')
    [void]$lines.Add(($pairs.ToArray() -join '; '))
    $action = [string](Get-CfgValue -Object $Report -Name 'ActionRequired' -Default '')
    if ($action -and $action -ne 'None') {
        [void]$lines.Add(('RMM ACTION: {0}' -f (Format-ShortText -Text $action)))
    }
    $issueCode = [string](Get-CfgValue -Object $Report -Name 'IssueCode' -Default '')
    if ($issueCode) {
        $detail = [string](Get-CfgValue -Object $Report -Name 'Detail' -Default '')
        [void]$lines.Add(('RMM ISSUE: {0} | {1}' -f $issueCode, (Format-ShortText -Text $detail)))
    }
    [void]$lines.Add('===================')
    return [string[]]$lines.ToArray()
}

# What the trap does for an unexpected error, by stage (spec 7.6).
function Get-TrapAction {
    param([string] $Stage = '')
    switch ($Stage) {
        'PATH_A_WRITING'  { return 'RESTORE_PATH_A' }
        'PATH_A_DONE'     { return 'NO_ROLLBACK' }
        'VERIFIED'        { return 'NO_ROLLBACK' }
        'PATH_B_CHANGING' { return 'ROLLBACK_PATH_B' }
        default           { return 'EXIT_UNHANDLED' }
    }
}

# Ends the run: resolves every issue, fills $script:Report, prints the RMM summary,
# writes <WorkRoot>\logs\last-result.json (only when $script:WorkRootReady is $true),
# stops the transcript, releases the run lock and exits. It never returns.
# Script variables, all read defensively: Issues, Report, Stage, WorkRoot (the
# script parameter), WorkRootReady, TranscriptStarted, RunLock. CompleteRunActive
# guards against a second call from the trap. -ExitCode without -Code raises the
# exit code to at least that value. -Detail without -Code is a note, not an issue:
# it goes at the end of Detail, so a run that exits 0 can still list what it did
# (spec 7.5 and 7.6 step 13: commented-out pg_hba.conf lines, roles that lost login).
function Complete-Run {
    param(
        [int] $ExitCode = 0,
        [string] $Code = '',
        [string] $Detail = '',
        [string] $Action = ''
    )
    if ((Get-Variable -Name CompleteRunActive -Scope Script -ValueOnly -ErrorAction SilentlyContinue) -eq $true) {
        exit $ExitCode
    }
    $script:CompleteRunActive = $true

    if ($Code) {
        Add-RunIssue -Code $Code -ExitCode $ExitCode -Detail $Detail -Action $Action
    }
    $issues = @()
    $issueList = Get-Variable -Name Issues -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $issueList) { $issues = @($issueList) }
    $outcome = Resolve-RunOutcome -Issues $issues
    $finalCode = [int]$outcome.ExitCode
    $issueCode = [string]$outcome.IssueCode
    $actionText = [string]$outcome.ActionRequired
    if (-not $Code -and $PSBoundParameters.ContainsKey('ExitCode') -and $ExitCode -gt $finalCode) {
        $finalCode = $ExitCode
        $actionText = Get-RmmActionForExitCode -ExitCode $finalCode
    }

    $report = Get-Variable -Name Report -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if (-not ($report -is [System.Collections.IDictionary])) {
        $report = New-RunReport -Mode 'UNKNOWN'
        $script:Report = $report
    }
    $stage = [string](Get-Variable -Name Stage -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if (-not $stage) { $stage = 'UNTOUCHED' }
    $fullDetail = [string]$outcome.Detail
    if (-not $Code -and $Detail) {
        if ($fullDetail) { $fullDetail = '{0} | {1}' -f $fullDetail, $Detail } else { $fullDetail = $Detail }
    }
    if ($fullDetail.Length -gt 900) { Write-Log ('Full detail: {0}' -f $fullDetail) 'INFO' }

    $report['Stage'] = $stage
    $report['ExitCode'] = $finalCode
    $report['IssueCode'] = $issueCode
    $report['ActionRequired'] = $actionText
    $report['Detail'] = Format-ShortText -Text $fullDetail -MaxLength 900
    if ($finalCode -eq 0) {
        $report['Outcome'] = 'OK'
    } elseif ($issueCode) {
        $report['Outcome'] = $issueCode
    } else {
        $report['Outcome'] = 'UNKNOWN'
    }

    Write-Host ''
    foreach ($summaryLine in @(Format-RmmSummary -Report $report)) {
        if ($summaryLine -like '=== RMM SUMMARY*') {
            Write-Host $summaryLine -ForegroundColor Magenta
        } elseif ($summaryLine -like 'RMM ACTION:*' -or $summaryLine -like 'RMM ISSUE:*') {
            Write-Host $summaryLine -ForegroundColor Yellow
        } else {
            Write-Host $summaryLine
        }
    }

    if ((Get-Variable -Name WorkRootReady -Scope Script -ValueOnly -ErrorAction SilentlyContinue) -eq $true) {
        $root = [string](Get-Variable -Name WorkRoot -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        if ($root) {
            try {
                Write-AtomicJson -Path (Join-Path (Join-Path $root 'logs') 'last-result.json') -Object $report
            } catch {
                Write-Log ('Could not write last-result.json: {0}' -f $_.Exception.Message) 'WARN'
            }
        }
    }

    if ((Get-Variable -Name TranscriptStarted -Scope Script -ValueOnly -ErrorAction SilentlyContinue) -eq $true) {
        try { Stop-Transcript | Out-Null } catch { Write-Log ('Could not stop the transcript: {0}' -f $_.Exception.Message) 'WARN' }
        $script:TranscriptStarted = $false
    }

    $lock = Get-Variable -Name RunLock -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $lock) {
        # Exit-RunLock (Task 3) never throws; the catch also covers a build without it.
        try { Exit-RunLock -Mutex $lock } catch { Write-Log ('Could not release the run lock: {0}' -f $_.Exception.Message) 'WARN' }
        $script:RunLock = $null
    }

    exit $finalCode
}
#endregion Outcome

#region Preflight
#endregion Preflight

#region Vbr
#endregion Vbr

#region PgDiscovery
#endregion PgDiscovery

#region Names
#endregion Names

#region Account
#endregion Account

#region ConfFiles
#endregion ConfFiles

#region PgHba
#endregion PgHba

#region PgIdent
#endregion PgIdent

#region Psql
#endregion Psql

#region State
#endregion State

#region Services
#endregion Services

#region Registry
#endregion Registry

#region ConnectCheck
#endregion ConnectCheck

#region PathA
#endregion PathA

#region PathB
#endregion PathB

#region MainHelpers
#endregion MainHelpers

# ===================== MAIN =====================
# Temporary main body so the file runs end to end. Task 18 replaces everything
# below the MAIN line with the real main body.
$EXIT = Get-ExitCodeTable
exit $EXIT.PREFLIGHT
