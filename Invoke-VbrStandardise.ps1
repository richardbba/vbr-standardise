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
# --- Host context (spec 7.1 steps 1-3 and 6) ---

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Pure decision for spec 7.1 steps 2-3. The first failing check wins. All exit 20.
# $PSEdition is a read-only automatic variable, so the parameter variable is
# $Edition and callers pass it as -PSEdition through the alias.
function Get-PreflightContextIssue {
    param(
        [Alias('PSEdition')][string] $Edition,
        [bool] $IsAdmin,
        [bool] $Is64BitOS,
        [bool] $Is64BitProcess,
        [string] $LanguageMode
    )
    if ($Edition -ne 'Desktop') {
        return [pscustomobject]@{
            Code     = 'WRONG_POWERSHELL'
            ExitCode = 20
            Detail   = "PowerShell edition is '$Edition'. This script needs Windows PowerShell 5.1 (Desktop edition)."
            Action   = 'Run %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
        }
    }
    if (-not $IsAdmin) {
        return [pscustomobject]@{
            Code     = 'NOT_ELEVATED'
            ExitCode = 20
            Detail   = 'The process is not elevated.'
            Action   = 'Run the script from RMM as SYSTEM, or from an elevated prompt'
        }
    }
    if ($Is64BitOS -and -not $Is64BitProcess) {
        return [pscustomobject]@{
            Code     = 'HOST_32BIT'
            ExitCode = 20
            Detail   = 'Windows is 64-bit but this PowerShell process is 32-bit.'
            Action   = 'Run 64-bit PowerShell: from a 32-bit RMM agent use %SystemRoot%\SysNative\WindowsPowerShell\v1.0\powershell.exe'
        }
    }
    if ($LanguageMode -ne 'FullLanguage') {
        return [pscustomobject]@{
            Code     = 'CONSTRAINED_LANGUAGE'
            ExitCode = 20
            Detail   = "PowerShell language mode is '$LanguageMode'. This script needs FullLanguage."
            Action   = 'Allow this script in the application control policy (WDAC or AppLocker) so it runs in FullLanguage mode'
        }
    }
    return $null
}

# Single instance (spec 7.1 step 1). The updater uses the same name, so the two
# scripts never run at the same time. An abandoned mutex (a run that was killed)
# still grants ownership and counts as acquired.
function Enter-RunLock {
    param([string] $Name = 'Global\VeeamPgUpdate')
    try {
        $mutex = New-Object System.Threading.Mutex($false, $Name)
    } catch {
        # The name exists but this process cannot open it, so another process has it.
        Write-Log -Message "Could not open the run lock '$Name': $($_.Exception.Message)" -Level 'WARN'
        return $null
    }
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
        Write-Log -Message 'Took over an abandoned run lock from a run that was killed.' -Level 'WARN'
    }
    if ($acquired) { return $mutex }
    $mutex.Dispose()
    return $null
}

function Exit-RunLock {
    param([System.Threading.Mutex] $Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { }
    try { $Mutex.Dispose() } catch { }
}

function Test-IsDomainController {
    $os = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction Stop
    return ([int]$os.ProductType -eq 2)
}
# --- WorkRoot trust boundary (adapted from Update-VeeamPostgres.ps1) ---
# The WorkRoot holds file backups and a registry export with the encrypted VBR
# database password. A folder name alone is not proof that the folder is ours:
# an ordinary user can create folders under C:\ProgramData and plant junctions.
# These helpers fail closed on reparse points and check the exact ACL the script
# sets. Well-known SIDs keep the checks language-neutral.

function Test-PathTreeHasReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [switch] $IncludeDescendants
    )
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $pathRoot = [IO.Path]::GetPathRoot($full)
        $current = $pathRoot
        $relative = $full.Substring($pathRoot.Length)
        foreach ($part in @($relative -split '[\\/]' | Where-Object { $_ })) {
            $current = Join-Path $current $part
            try { $attributes = [IO.File]::GetAttributes($current) }
            catch [IO.FileNotFoundException] { break }
            catch [IO.DirectoryNotFoundException] { break }
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        }
        if ($IncludeDescendants -and (Test-Path -LiteralPath $full -PathType Container)) {
            $pending = New-Object 'System.Collections.Generic.Queue[string]'
            $pending.Enqueue($full)
            while ($pending.Count -gt 0) {
                $directory = $pending.Dequeue()
                foreach ($child in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
                    if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
                    if ($child.PSIsContainer) { $pending.Enqueue($child.FullName) }
                }
            }
        }
        return $false
    } catch {
        # A path that cannot be inspected is not a safe place for privileged data.
        return $true
    }
}

# A regular file owned by SYSTEM or Administrators that no other principal can change.
function Test-RegularTrustedFile {
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        $trustedSids = @('S-1-5-18', 'S-1-5-32-544')
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if ($trustedSids -notcontains $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value) { return $false }
        $dangerous = [int64]([System.Security.AccessControl.FileSystemRights]::Write -bor
                             [System.Security.AccessControl.FileSystemRights]::Delete -bor
                             [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                             [System.Security.AccessControl.FileSystemRights]::TakeOwnership) -bor
                     [int64]0x10000000 -bor [int64]0x40000000
        foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                $trustedSids -notcontains $rule.IdentityReference.Value -and
                ([int64]$rule.FileSystemRights -band $dangerous) -ne 0) {
                return $false
            }
        }
        return $true
    } catch { return $false }
}

# Exactly: inheritance off, owner Administrators, two Allow FullControl rules
# (SYSTEM and Administrators) that apply to this folder, subfolders and files.
function Test-ProtectedFolderAcl {
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if (-not $acl.AreAccessRulesProtected) { return $false }
        if ($acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') { return $false }
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        if ($rules.Count -ne 2) { return $false }
        $requiredInheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                               [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $matching = @($rules | Where-Object { $_.IdentityReference.Value -eq $sid })
            if ($matching.Count -ne 1) { return $false }
            $rule = $matching[0]
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
                $rule.IsInherited -or
                [int]$rule.FileSystemRights -ne [int][System.Security.AccessControl.FileSystemRights]::FullControl -or
                [int]$rule.InheritanceFlags -ne [int]$requiredInheritance -or
                $rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None) {
                return $false
            }
        }
        return $true
    } catch { return $false }
}

# No folder from the drive root down to Path may let an untrusted principal
# delete or replace children, or rewrite the ACL. Create-folder rights alone are
# allowed: a new WorkRoot is created under a random staging name and renamed.
function Test-SafeWorkRootParent {
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        if (Test-PathTreeHasReparsePoint -Path $Path) { return $false }
        $trustedSids = @(
            'S-1-5-18',
            'S-1-5-32-544',
            'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
        )
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $currentPrincipal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
        if ($currentPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
            $trustedSids += $currentIdentity.User.Value
        }
        $dangerous = [int64]([System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
                             [System.Security.AccessControl.FileSystemRights]::Delete -bor
                             [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                             [System.Security.AccessControl.FileSystemRights]::TakeOwnership) -bor
                     [int64]0x10000000 -bor
                     [int64]0x40000000
        $resolvedPath = [IO.Path]::GetFullPath($Path)
        $pathRoot = [IO.Path]::GetPathRoot($resolvedPath)
        if ($resolvedPath.TrimEnd('\') -ieq $pathRoot.TrimEnd('\')) { $full = $pathRoot } else { $full = $resolvedPath.TrimEnd('\') }
        $components = @($pathRoot)
        $current = $pathRoot
        $relative = $full.Substring($pathRoot.Length)
        foreach ($part in @($relative -split '[\\/]' | Where-Object { $_ })) {
            $current = Join-Path $current $part
            $components += $current
        }
        foreach ($component in $components) {
            $item = Get-Item -LiteralPath $component -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
            $acl = Get-Acl -LiteralPath $component -ErrorAction Stop
            if ($trustedSids -notcontains $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value) { return $false }
            foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
                if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
                if ($trustedSids -contains $rule.IdentityReference.Value) { continue }
                if (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
                if (([int64]$rule.FileSystemRights -band $dangerous) -ne 0) { return $false }
            }
        }
        return $true
    } catch { return $false }
}

# Creates Path with the protected ACL in one native call under a random staging
# name, checks it, then renames it into place. Returns $true only when the final
# folder has exactly the protected ACL and no reparse point.
function New-ProtectedDirectory {
    param([Parameter(Mandatory = $true)][string] $Path)
    $stage = $null
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $parent = [IO.Directory]::GetParent($full).FullName
        if (-not (Test-SafeWorkRootParent -Path $parent) -or (Test-Path -LiteralPath $full)) { return $false }
        $stage = Join-Path $parent ('.vbr-standardise-stage-' + [guid]::NewGuid().ToString('N'))
        $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $stageAcl = New-Object System.Security.AccessControl.DirectorySecurity
        $stageAcl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($system, $admins)) {
            $stageAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        $stageAcl.SetOwner($admins)
        # Create with the final DACL in the same native call. Creating first and
        # calling Set-Acl later leaves a writable folder open to a junction swap.
        $stageInfo = New-Object System.IO.DirectoryInfo($stage)
        if ($PSVersionTable.PSEdition -eq 'Core') {
            [System.IO.FileSystemAclExtensions]::Create($stageInfo, $stageAcl)
        } else {
            $stageInfo.Create($stageAcl)
        }
        if (-not (Test-ProtectedFolderAcl -Path $stage)) { return $false }
        if (Test-PathTreeHasReparsePoint -Path $stage -IncludeDescendants) { return $false }
        if (@(Get-ChildItem -LiteralPath $stage -Force -ErrorAction Stop).Count -ne 0) { return $false }
        [IO.Directory]::Move($stage, $full)
        $stage = $null
        return ((Test-ProtectedFolderAcl -Path $full) -and -not (Test-PathTreeHasReparsePoint -Path $full -IncludeDescendants))
    } catch {
        return $false
    } finally {
        if ($stage -and (Test-Path -LiteralPath $stage) -and
            (Test-ProtectedFolderAcl -Path $stage) -and
            -not (Test-PathTreeHasReparsePoint -Path $stage -IncludeDescendants)) {
            try { [IO.Directory]::Delete($stage, $true) } catch { }
        }
    }
}

# The updater's legacy marker test (Get-TrustedLegacyRecoveryMarker): a marker
# under a folder that ordinary users can write (C:\temp) counts only when no part
# of its path is a reparse point and the file is owned by and writable only by
# SYSTEM or Administrators.
function Test-TrustedLegacyMarker {
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        if (Test-PathTreeHasReparsePoint -Path $Path) { return $false }
        return (Test-RegularTrustedFile -Path $Path)
    } catch { return $false }
}

# Takes charge only of a folder this script created: a new folder, an empty
# folder that already has the protected ACL, or a folder with the protected ACL
# and this script's sentinel file. Never changes the ACL of an existing folder.
function Initialize-WorkRoot {
    param([Parameter(Mandatory = $true)][string] $Path)
    $sentinelText = 'Created by Invoke-VbrStandardise.ps1. Marks this folder as safe for the script to lock down and clean up.'
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = "invalid WorkRoot path '$Path': $($_.Exception.Message)" }
    }
    if ($full -ieq $root) {
        return [pscustomobject]@{ Ok = $false; Detail = "$Path is the root of a drive or share" }
    }
    if (Test-PathTreeHasReparsePoint -Path $full) {
        return [pscustomobject]@{ Ok = $false; Detail = "$full or one of its parent folders is a reparse point" }
    }
    $parent = [IO.Directory]::GetParent($full).FullName
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        # Never create a missing parent: the default parent C:\ProgramData always exists.
        return [pscustomobject]@{ Ok = $false; Detail = "parent folder does not exist: $parent" }
    }
    if (-not (Test-SafeWorkRootParent -Path $parent)) {
        return [pscustomobject]@{ Ok = $false; Detail = "parent folder can be replaced by a non-administrator or has an untrusted owner: $parent" }
    }
    if (-not (Test-Path -LiteralPath $full)) {
        if (-not (New-ProtectedDirectory -Path $full)) {
            return [pscustomobject]@{ Ok = $false; Detail = "could not create a protected WorkRoot at $full" }
        }
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        return [pscustomobject]@{ Ok = $false; Detail = "$full is not a folder" }
    }
    if (Test-PathTreeHasReparsePoint -Path $full -IncludeDescendants) {
        return [pscustomobject]@{ Ok = $false; Detail = "$full contains a reparse point" }
    }
    if (-not (Test-ProtectedFolderAcl -Path $full)) {
        return [pscustomobject]@{ Ok = $false; Detail = "$full does not have the SYSTEM + Administrators only ACL with owner Administrators; remove the folder or fix its ACL" }
    }
    $sentinel = Join-Path $full '.vbr-standardise'
    try {
        $children = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop)
        if ($children.Count -eq 0) {
            [IO.File]::WriteAllText($sentinel, $sentinelText, (New-Object System.Text.UTF8Encoding($false)))
            $sentinelAcl = Get-Acl -LiteralPath $sentinel -ErrorAction Stop
            $owner = $sentinelAcl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            if ($owner -ne 'S-1-5-18' -and $owner -ne 'S-1-5-32-544') {
                $sentinelAcl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
                Set-Acl -LiteralPath $sentinel -AclObject $sentinelAcl -ErrorAction Stop
            }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = "could not write the WorkRoot sentinel in ${full}: $($_.Exception.Message)" }
    }
    $sentinelOk = $false
    if (Test-RegularTrustedFile -Path $sentinel) {
        try { $sentinelOk = ([IO.File]::ReadAllText($sentinel).TrimEnd([char[]]"`r`n") -ceq $sentinelText) } catch { $sentinelOk = $false }
    }
    if (-not $sentinelOk) {
        return [pscustomobject]@{ Ok = $false; Detail = "$full is not empty and has no trusted sentinel file from this script" }
    }
    try {
        foreach ($sub in @('logs', 'runs')) {
            $subPath = Join-Path $full $sub
            if (-not (Test-Path -LiteralPath $subPath)) { [void][IO.Directory]::CreateDirectory($subPath) }
            if (-not (Test-Path -LiteralPath $subPath -PathType Container)) {
                return [pscustomobject]@{ Ok = $false; Detail = "$subPath is not a folder" }
            }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = "could not create the logs and runs folders in ${full}: $($_.Exception.Message)" }
    }
    if (Test-PathTreeHasReparsePoint -Path $full -IncludeDescendants) {
        return [pscustomobject]@{ Ok = $false; Detail = "$full contains a reparse point" }
    }
    return [pscustomobject]@{ Ok = $true; Detail = '' }
}
# --- Markers, run folders, last failure and retention (spec 7.1 step 5, 7.6, 7.7) ---

# UpdaterPaths[0] is the updater's current marker and counts whenever it exists.
# Every later entry is a legacy marker under a user-writable folder and counts
# only when Test-TrustedLegacyMarker accepts it.
function Find-ChangeMarkers {
    param(
        [Parameter(Mandatory = $true)][string] $WorkRoot,
        [string[]] $UpdaterPaths = @(
            'C:\ProgramData\VeeamPgUpdate\CHANGES-IN-PROGRESS.marker',
            'C:\temp\VeeamPgUpdate\CHANGES-IN-PROGRESS.marker'
        )
    )
    $found = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $own = Join-Path $WorkRoot 'CHANGES-IN-PROGRESS.marker'
    [void]$seen.Add([IO.Path]::GetFullPath($own))
    if (Test-Path -LiteralPath $own) { [void]$found.Add($own) }
    $candidates = @($UpdaterPaths)
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $candidate = "$($candidates[$i])"
        if (-not $candidate) { continue }
        if (-not $seen.Add([IO.Path]::GetFullPath($candidate))) { continue }
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        if ($i -eq 0 -or (Test-TrustedLegacyMarker -Path $candidate)) { [void]$found.Add($candidate) }
    }
    return [string[]]$found.ToArray()
}

function New-RunFolder {
    param(
        [Parameter(Mandatory = $true)][string] $WorkRoot,
        [Parameter(Mandatory = $true)][string] $Stamp
    )
    if ($Stamp -notmatch '^[0-9A-Za-z_-]+$') { throw "Invalid run stamp '$Stamp'." }
    $path = Join-Path (Join-Path $WorkRoot 'runs') $Stamp
    # Never reuse a folder: it may hold another run's backups.
    if (Test-Path -LiteralPath $path) { throw "The run folder already exists: $path" }
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Write-ChangeMarker {
    param(
        [Parameter(Mandatory = $true)][string] $WorkRoot,
        [Parameter(Mandatory = $true)][string] $RunDir,
        [Parameter(Mandatory = $true)][string] $PathName,
        [Parameter(Mandatory = $true)][string] $Stage
    )
    $marker = Join-Path $WorkRoot 'CHANGES-IN-PROGRESS.marker'
    Write-AtomicJson -Path $marker -Object ([ordered]@{
        RunDir = $RunDir
        Path   = $PathName
        Stage  = $Stage
        Time   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    })
}

# Returns $true when no marker is left (removed now, or already absent).
function Remove-ChangeMarker {
    param([Parameter(Mandatory = $true)][string] $WorkRoot)
    $marker = Join-Path $WorkRoot 'CHANGES-IN-PROGRESS.marker'
    try {
        if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force -ErrorAction Stop }
    } catch {
        Write-Log -Message "Could not remove the change marker ${marker}: $($_.Exception.Message)" -Level 'ERROR'
    }
    return (-not (Test-Path -LiteralPath $marker))
}

function Write-LastFailure {
    param(
        [Parameter(Mandatory = $true)][string] $WorkRoot,
        [Parameter(Mandatory = $true)][string] $RunDir,
        [Parameter(Mandatory = $true)][string] $Reason
    )
    Write-AtomicJson -Path (Join-Path $WorkRoot 'last-failure.json') -Object ([ordered]@{
        Computer = $env:COMPUTERNAME
        RunDir   = $RunDir
        Reason   = $Reason
        Time     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    })
}

function Test-LastFailure {
    param([Parameter(Mandatory = $true)][string] $WorkRoot)
    return [bool](Test-Path -LiteralPath (Join-Path $WorkRoot 'last-failure.json'))
}

# Deletes logs\VbrStandardise_*.log files and runs\* folders whose last write is
# older than RetentionDays. Never deletes the marker or last-failure.json. Keeps
# every run folder while a marker exists, and keeps the run folder named in
# last-failure.json, because a person needs them to recover or investigate.
function Remove-OldRunData {
    param(
        [Parameter(Mandatory = $true)][string] $WorkRoot,
        [Parameter(Mandatory = $true)][int] $RetentionDays
    )
    if ($RetentionDays -lt 1) {
        Write-Log -Message "RetentionDays is $RetentionDays, so no old run data is deleted." -Level 'WARN'
        return
    }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $removed = 0
    $logs = Join-Path $WorkRoot 'logs'
    if ((Test-Path -LiteralPath $logs -PathType Container) -and -not (Test-PathTreeHasReparsePoint -Path $logs)) {
        foreach ($log in @(Get-ChildItem -LiteralPath $logs -File -Force -Filter 'VbrStandardise_*.log' -ErrorAction SilentlyContinue)) {
            if (($log.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($log.LastWriteTime -ge $cutoff) { continue }
            Remove-Item -LiteralPath $log.FullName -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $log.FullName)) { $removed++ }
        }
    }
    $runs = Join-Path $WorkRoot 'runs'
    if (-not (Test-Path -LiteralPath $runs -PathType Container)) {
        Write-Log -Message "Retention: removed $removed old item(s)."
        return
    }
    if (Test-Path -LiteralPath (Join-Path $WorkRoot 'CHANGES-IN-PROGRESS.marker')) {
        Write-Log -Message 'Retention: a change marker exists, so every run folder is kept.' -Level 'WARN'
        return
    }
    if (Test-PathTreeHasReparsePoint -Path $runs) {
        Write-Log -Message "Retention: $runs is or sits under a reparse point, so every run folder is kept." -Level 'WARN'
        return
    }
    $keep = ''
    $lastFailure = Join-Path $WorkRoot 'last-failure.json'
    if (Test-Path -LiteralPath $lastFailure) {
        try {
            $failure = [IO.File]::ReadAllText($lastFailure) | ConvertFrom-Json
            $keepDir = "$(Get-CfgValue -Object $failure -Name 'RunDir' -Default '')"
            if ($keepDir) { $keep = [IO.Path]::GetFullPath($keepDir).TrimEnd('\') }
        } catch {
            Write-Log -Message 'Retention: last-failure.json cannot be read, so every run folder is kept.' -Level 'WARN'
            return
        }
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $runs -Directory -Force -ErrorAction SilentlyContinue)) {
        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if ($dir.LastWriteTime -ge $cutoff) { continue }
        $full = [IO.Path]::GetFullPath($dir.FullName).TrimEnd('\')
        if ($keep -and $full -ieq $keep) { continue }
        if (Test-PathTreeHasReparsePoint -Path $full -IncludeDescendants) {
            Write-Log -Message "Retention: keeping $full because it contains a reparse point." -Level 'WARN'
            continue
        }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $full)) { $removed++ }
    }
    Write-Log -Message "Retention: removed $removed old item(s)."
}
#endregion Preflight

#region Vbr
# --- VBR install, products and registry (spec 7.1 steps 7-10, 7.5, 9) ---

# VBR is installed when the CorePath folder exists (same test as the updater).
function Get-VbrInstall {
    param([string] $RootKey = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication')
    $corePath = "$(Get-RegValue -Path $RootKey -Name 'CorePath')"
    if (-not $corePath -or -not (Test-Path -LiteralPath $corePath -PathType Container)) {
        return [pscustomobject]@{ Installed = $false; CorePath = $corePath; Version = '' }
    }
    $version = ''
    foreach ($relative in @('Veeam.Backup.Service.exe', 'Packages\VeeamDeploymentDll.dll')) {
        $file = Join-Path $corePath $relative
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            try { $version = "$((Get-Item -LiteralPath $file -Force).VersionInfo.ProductVersion)".Trim() } catch { $version = '' }
        }
        if ($version) { break }
    }
    if (-not $version) { $version = 'Unknown' }
    return [pscustomobject]@{ Installed = $true; CorePath = $corePath; Version = $version }
}

# The service OR the executable proves VB365. A leftover empty folder does not.
function Test-Vb365Installed {
    $service = Get-Service -Name 'Veeam.Archiver.Service' -ErrorAction SilentlyContinue
    if ($null -ne $service) { return $true }
    return [bool](Test-Path -LiteralPath 'C:\Program Files\Veeam\Backup365\Veeam.Archiver.Service.exe' -PathType Leaf)
}

# Reads a registry value as a TCP port: [int] in 1-65535, otherwise $null (value
# absent, text or out of range). The one place that decides what a valid port is.
function Get-RegPort {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Name
    )
    $raw = Get-RegValue -Path $Path -Name $Name
    $number = 0
    if ($null -ne $raw -and [int]::TryParse("$raw", [ref]$number) -and $number -ge 1 -and $number -le 65535) { return $number }
    return $null
}

# Reads the VBR database settings. Password values are reduced to "set or not"
# at once and never returned. Missing text values come back as ''. Port and
# EntraIdPort are [int] in 1-65535, otherwise $null.
function Get-VbrDbConfig {
    param([string] $RootKey = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication')
    $root = $RootKey.TrimEnd('\')
    $configKey = "$root\DatabaseConfigurations"
    $keyPath = "$configKey\PostgreSql"
    return [pscustomobject]@{
        RootKey             = $RootKey
        KeyPath             = $keyPath
        ActiveConfiguration = "$(Get-RegValue -Path $configKey -Name 'SqlActiveConfiguration')"
        HostName            = "$(Get-RegValue -Path $keyPath -Name 'SqlHostName')"
        Port                = (Get-RegPort -Path $keyPath -Name 'SqlHostPort')
        DatabaseName        = "$(Get-RegValue -Path $keyPath -Name 'SqlDatabaseName')"
        UserName            = "$(Get-RegValue -Path $keyPath -Name 'SqlUserName')"
        PasswordSet         = ("$(Get-RegValue -Path $keyPath -Name 'SqlSecuredPassword')".Length -gt 0)
        WindowsAuthRole     = "$(Get-RegValue -Path $keyPath -Name 'PostgresUserForWindowsAuth')"
        EntraIdHost         = "$(Get-RegValue -Path $root -Name 'EntraIdSqlHostName')"
        EntraIdPort         = (Get-RegPort -Path $root -Name 'EntraIdSqlHostPort')
        EntraIdPasswordSet  = ("$(Get-RegValue -Path $root -Name 'EntraIdSqlPassword')".Length -gt 0)
    }
}

# Enterprise Manager uses the same layout under its own root key.
function Get-EnterpriseManagerDbConfig {
    param([string] $RootKey = 'HKLM:\SOFTWARE\Veeam\Veeam Backup Reporting')
    $root = $RootKey.TrimEnd('\')
    $configKey = "$root\DatabaseConfigurations"
    if (-not (Test-Path -LiteralPath $configKey)) { return $null }
    $keyPath = "$configKey\PostgreSql"
    return [pscustomobject]@{
        ActiveConfiguration = "$(Get-RegValue -Path $configKey -Name 'SqlActiveConfiguration')"
        HostName            = "$(Get-RegValue -Path $keyPath -Name 'SqlHostName')"
        Port                = (Get-RegPort -Path $keyPath -Name 'SqlHostPort')
        PasswordSet         = ("$(Get-RegValue -Path $keyPath -Name 'SqlSecuredPassword')".Length -gt 0)
    }
}

# The local network adapters. A function of its own so a test can supply fakes.
function Get-LocalNetworkInterfaces {
    return @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces())
}

# Computer name, FQDN and every address on a local network interface (loopback
# included). DNS answers are used for names only, never for addresses, because a
# stale DNS record can name another server.
function Get-LocalHostNames {
    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add($env:COMPUTERNAME)
    try {
        $ipProps = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        [void]$candidates.Add($ipProps.HostName)
        if ($ipProps.DomainName) { [void]$candidates.Add("$($ipProps.HostName).$($ipProps.DomainName)") }
    } catch {
        Write-Log -Message "Could not read the host and domain name from the network stack: $($_.Exception.Message)" -Level 'WARN'
    }
    # A missing DNS record is normal, so this catch stays quiet.
    try {
        $entry = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)
        [void]$candidates.Add($entry.HostName)
        foreach ($alias in @($entry.Aliases)) { [void]$candidates.Add($alias) }
    } catch { }
    # The interfaces are the only source of local IP addresses. One adapter that
    # fails is skipped and logged; it must not drop the addresses of the others.
    $nics = @()
    try {
        $nics = @(Get-LocalNetworkInterfaces)
    } catch {
        Write-Log -Message "Could not list the network adapters, so local IP addresses are unknown: $($_.Exception.Message)" -Level 'WARN'
    }
    foreach ($nic in $nics) {
        try {
            foreach ($unicast in @($nic.GetIPProperties().UnicastAddresses)) {
                $text = $unicast.Address.ToString()
                [void]$candidates.Add($text)
                if ($text.Contains('%')) { [void]$candidates.Add($text.Split('%')[0]) }
            }
        } catch {
            Write-Log -Message "Skipped network adapter '$($nic.Name)', its IP addresses are not listed: $($_.Exception.Message)" -Level 'WARN'
        }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $names = New-Object System.Collections.ArrayList
    foreach ($candidate in $candidates) {
        $value = "$candidate".Trim()
        if ($value.Length -gt 1) { $value = $value.TrimEnd('.') }
        if ($value -and $seen.Add($value)) { [void]$names.Add($value) }
    }
    return [string[]]$names.ToArray()
}

# LOOPBACK, LOCAL (one of LocalNames) or REMOTE. An empty host is not proven
# local, so it is REMOTE (fail closed). IPv6 text is compared in canonical form.
function Get-DbHostClass {
    param(
        [string] $HostName,
        [string[]] $LocalNames
    )
    $normalise = {
        param([string] $Text)
        $value = "$Text".Trim().Trim([char[]]@('[', ']'))
        if ($value.Length -gt 1) { $value = $value.TrimEnd('.') }
        $address = $null
        if ($value.Contains(':') -and [System.Net.IPAddress]::TryParse($value, [ref]$address)) { $value = $address.ToString() }
        return $value
    }
    $candidate = & $normalise $HostName
    if (-not $candidate) { return 'REMOTE' }
    if (@('localhost', '127.0.0.1', '::1') -contains $candidate) { return 'LOOPBACK' }
    foreach ($name in @($LocalNames)) {
        $local = & $normalise $name
        if ($local -and $local -ieq $candidate) { return 'LOCAL' }
    }
    return 'REMOTE'
}

# Spec 9: Windows authentication when SqlUserName and SqlSecuredPassword are
# both empty or absent; native when either one has data.
function Get-RegistryAuthMode {
    param(
        [string] $UserName,
        [bool] $PasswordSet
    )
    if ([string]::IsNullOrEmpty($UserName) -and -not $PasswordSet) { return 'WINDOWS' }
    return 'NATIVE'
}
#endregion Vbr

#region PgDiscovery
# Copied from Update-VeeamPostgres.ps1 without changes: the service command must
# start pg_ctl.exe or postgres.exe from the registry Base Directory.
function Test-PgServiceExecutableMatchesBaseDir {
    param(
        [Parameter(Mandatory)][string] $PathName,
        [Parameter(Mandatory)][string] $BaseDir
    )

    $commandLine = [Environment]::ExpandEnvironmentVariables($PathName).Trim()
    $executable = $null
    if ($commandLine -match '^\s*"([^"]+\.exe)"(?:\s|$)') {
        $executable = $Matches[1]
    } elseif ($commandLine -match '^\s*(.+?\.exe)(?:\s|$)') {
        $executable = $Matches[1]
    }
    if (-not $executable) { return $false }

    try {
        $actual = [IO.Path]::GetFullPath($executable).TrimEnd('\')
        $expected = @(
            (Join-Path $BaseDir 'bin\pg_ctl.exe'),
            (Join-Path $BaseDir 'bin\postgres.exe')
        ) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
        return (@($expected | Where-Object { $_ -ieq $actual }).Count -eq 1)
    } catch {
        return $false
    }
}
# Adapted from the updater's STEP 5. It returns a result instead of calling
# Complete-Run, and takes the service list as a parameter so tests can inject it.
# The main body maps the codes to exits: NO_PG_FOUND 20, PG_NOT_RUNNING 20, MULTIPLE_PG 11.
function Find-PgInstall {
    param(
        [string] $InstallationsKey = 'HKLM:\SOFTWARE\PostgreSQL\Installations',
        [AllowNull()][AllowEmptyCollection()][object[]] $Services
    )

    $result = [pscustomobject]@{
        Ok          = $false
        Code        = ''
        Detail      = ''
        Version     = $null
        Major       = 0
        BaseDir     = $null
        DataDir     = $null
        ServiceName = $null
        Psql        = $null
        HbaPath     = $null
        IdentPath   = $null
    }

    $installs = @()
    if (Test-Path -LiteralPath $InstallationsKey) {
        foreach ($k in @(Get-ChildItem -LiteralPath $InstallationsKey -ErrorAction Stop)) {
            $installs += [pscustomobject]@{
                Key       = $k.PSChildName
                Version   = Get-RegValue -Path $k.PSPath -Name 'Version'
                BaseDir   = Get-RegValue -Path $k.PSPath -Name 'Base Directory'
                DataDir   = Get-RegValue -Path $k.PSPath -Name 'Data Directory'
                ServiceID = Get-RegValue -Path $k.PSPath -Name 'Service ID'
            }
        }
    }
    if ($installs.Count -eq 0) {
        $result.Code = 'NO_PG_FOUND'
        $result.Detail = "No PostgreSQL installation found under $InstallationsKey."
        return $result
    }
    if ($installs.Count -gt 1) {
        $list = @($installs | ForEach-Object { "$($_.Key): $($_.Version) at $($_.BaseDir)" }) -join ' | '
        $result.Code = 'MULTIPLE_PG'
        $result.Detail = "More than one PostgreSQL installation is registered ($list). Mapping one of them to VBR is ambiguous; handle manually."
        return $result
    }

    $pg = $installs[0]
    $result.Version = $pg.Version
    $result.BaseDir = $pg.BaseDir
    $result.DataDir = $pg.DataDir
    $missing = @()
    if (-not "$($pg.Version)".Trim()) { $missing += 'Version' }
    if (-not "$($pg.BaseDir)".Trim()) { $missing += 'Base Directory' }
    if (-not "$($pg.DataDir)".Trim()) { $missing += 'Data Directory' }
    if ($missing.Count -gt 0) {
        $result.Code = 'NO_PG_FOUND'
        $result.Detail = "The PostgreSQL registry entry '$($pg.Key)' has no value for: $($missing -join ', '). Cannot proceed safely."
        return $result
    }
    $majorMatch = [regex]::Match("$($pg.Version)", '^\s*(\d+)')
    if (-not $majorMatch.Success) {
        $result.Code = 'NO_PG_FOUND'
        $result.Detail = "The PostgreSQL registry entry '$($pg.Key)' has Version '$($pg.Version)', which is not a version number."
        return $result
    }
    $result.Major = [int]$majorMatch.Groups[1].Value

    $all = @()
    if ($PSBoundParameters.ContainsKey('Services')) {
        $all = @($Services)
    } else {
        try {
            $all = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
        } catch {
            $result.Code = 'NO_PG_FOUND'
            $result.Detail = "Could not list Windows services to find the PostgreSQL service: $($_.Exception.Message)"
            return $result
        }
    }
    $rows = @()
    foreach ($s in $all) {
        if ($null -eq $s) { continue }
        $rows += [pscustomobject]@{
            Name     = "$(Get-CfgValue -Object $s -Name 'Name')"
            State    = "$(Get-CfgValue -Object $s -Name 'State')"
            PathName = "$(Get-CfgValue -Object $s -Name 'PathName')"
        }
    }
    $candidates = @($rows | Where-Object {
        $_.Name -like 'postgresql*' -or
        $_.PathName -match '(?i)(?:^|[\\/"])(?:pg_ctl|postgres)\.exe(?:["\s]|$)'
    })
    # Some vendor wrappers hide pg_ctl.exe from PathName. Always include the exact
    # registry Service ID when it exists, then still reject every multi-service case.
    $serviceId = "$($pg.ServiceID)".Trim()
    if ($serviceId) {
        $byId = @($rows | Where-Object { $_.Name -ieq $serviceId })
        if ($byId.Count -gt 0) { $candidates += $byId[0] }
    }
    $pgRows = @()
    $seenNames = @{}
    foreach ($row in $candidates) {
        $nameKey = $row.Name.ToLowerInvariant()
        if ($seenNames.ContainsKey($nameKey)) { continue }
        $seenNames[$nameKey] = $true
        $pgRows += $row
    }
    if ($pgRows.Count -gt 1) {
        $list = @($pgRows | ForEach-Object { "$($_.Name) [$($_.PathName)]" }) -join ' | '
        $result.Code = 'MULTIPLE_PG'
        $result.Detail = "More than one PostgreSQL Windows service exists ($list). This script supports one local PostgreSQL cluster only."
        return $result
    }
    if ($pgRows.Count -eq 0) {
        $result.Code = 'NO_PG_FOUND'
        $result.Detail = "PostgreSQL is registered at '$($pg.BaseDir)', but no PostgreSQL Windows service was found (Service ID '$serviceId')."
        return $result
    }

    $svc = $pgRows[0]
    $result.ServiceName = $svc.Name
    if ($serviceId -and $svc.Name -ine $serviceId) {
        $result.Code = 'NO_PG_FOUND'
        $result.Detail = "The only PostgreSQL service is '$($svc.Name)', but the registry names service '$serviceId'. Refusing an ambiguous installation."
        return $result
    }
    $binaryOk = $false
    if ($svc.PathName) { $binaryOk = Test-PgServiceExecutableMatchesBaseDir -PathName $svc.PathName -BaseDir "$($pg.BaseDir)" }
    if (-not $binaryOk) {
        $result.Code = 'NO_PG_FOUND'
        $result.Detail = "PostgreSQL service '$($svc.Name)' does not run pg_ctl.exe or postgres.exe from the registry Base Directory '$($pg.BaseDir)'. Service command: $($svc.PathName)"
        return $result
    }

    $result.Psql = [IO.Path]::Combine("$($pg.BaseDir)", 'bin\psql.exe')
    $result.HbaPath = [IO.Path]::Combine("$($pg.DataDir)", 'pg_hba.conf')
    $result.IdentPath = [IO.Path]::Combine("$($pg.DataDir)", 'pg_ident.conf')
    if (-not (Test-Path -LiteralPath $result.Psql -PathType Leaf)) {
        $result.Code = 'NO_PG_FOUND'
        $result.Detail = "psql.exe not found at '$($result.Psql)'."
        return $result
    }
    if ($svc.State -ne 'Running') {
        $result.Code = 'PG_NOT_RUNNING'
        $result.Detail = "PostgreSQL service '$($svc.Name)' is $($svc.State). Start it and find out why it stopped, then re-run."
        return $result
    }

    $result.Ok = $true
    $result.Detail = "PostgreSQL $($pg.Version) at '$($pg.BaseDir)', data '$($pg.DataDir)', service '$($svc.Name)'."
    return $result
}
# postmaster.pid lines: 1 PID, 2 data directory, 3 start time, 4 port, 5 socket
# directory, 6 listen address, 7 shared memory key, 8 status. Throws when malformed.
function ConvertFrom-PostmasterPid {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $lines = @($Text -split "`n" | ForEach-Object { $_.TrimEnd([char]13) })
    if ($lines.Count -lt 4) { throw "postmaster.pid has $($lines.Count) line(s); expected at least 4." }
    $pidValue = 0
    if (-not [int]::TryParse($lines[0].Trim(), [ref]$pidValue) -or $pidValue -le 0) {
        throw "postmaster.pid line 1 is not a process ID: '$($lines[0])'"
    }
    $portValue = 0
    if (-not [int]::TryParse($lines[3].Trim(), [ref]$portValue) -or $portValue -lt 1 -or $portValue -gt 65535) {
        throw "postmaster.pid line 4 is not a TCP port: '$($lines[3])'"
    }
    $dir = $lines[1].Trim()
    if (-not $dir) { throw 'postmaster.pid line 2 (data directory) is empty.' }
    return [pscustomobject]@{ Pid = $pidValue; DataDir = $dir; Port = $portValue }
}

# Proves without SQL that the registry Data Directory is the live cluster:
# its postmaster.pid names this folder, a running postgres.exe and the VBR port.
function Test-PostmasterLive {
    param(
        [Parameter(Mandatory)][string] $DataDir,
        [Parameter(Mandatory)][int] $ExpectedPort
    )

    $pidPath = [IO.Path]::Combine($DataDir, 'postmaster.pid')
    if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Detail = "No postmaster.pid in '$DataDir'. No running PostgreSQL uses the registry Data Directory." }
    }
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($pidPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::Default)
            $text = $reader.ReadToEnd()
        } finally {
            $stream.Dispose()
        }
        $info = ConvertFrom-PostmasterPid -Text $text
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = "Could not read '$pidPath': $($_.Exception.Message)" }
    }

    try {
        $fromFile = [IO.Path]::GetFullPath(($info.DataDir -replace '/', '\')).TrimEnd('\')
        $expected = [IO.Path]::GetFullPath(($DataDir -replace '/', '\')).TrimEnd('\')
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = "Could not compare data directory '$($info.DataDir)' with '$DataDir': $($_.Exception.Message)" }
    }
    if ($fromFile -ine $expected) {
        return [pscustomobject]@{ Ok = $false; Detail = "postmaster.pid in '$DataDir' names data directory '$($info.DataDir)'. It does not belong to this folder." }
    }

    $proc = $null
    try { $proc = Get-Process -Id $info.Pid -ErrorAction SilentlyContinue } catch { $proc = $null }
    if ($null -eq $proc) {
        return [pscustomobject]@{ Ok = $false; Detail = "PID $($info.Pid) from postmaster.pid in '$DataDir' is not running. The file is stale." }
    }
    $procName = "$(@($proc)[0].ProcessName)"
    if ($procName -ine 'postgres') {
        return [pscustomobject]@{ Ok = $false; Detail = "PID $($info.Pid) from postmaster.pid in '$DataDir' is '$procName', not postgres.exe." }
    }
    if ($info.Port -ne $ExpectedPort) {
        return [pscustomobject]@{ Ok = $false; Detail = "PostgreSQL for '$DataDir' uses port $($info.Port), but VBR uses port $ExpectedPort (SqlHostPort)." }
    }
    return [pscustomobject]@{ Ok = $true; Detail = "postgres.exe PID $($info.Pid) runs '$DataDir' on port $($info.Port)." }
}
# postgresql.conf syntax: name [=] value, '#' starts a comment outside quotes,
# single-quoted values with '' or \' for a quote. Returns the last active value.
function Get-PgConfSetting {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines,
        [Parameter(Mandatory)][string] $Name
    )

    $pattern = "^\s*([A-Za-z_][A-Za-z0-9_.\-]*)\s*(?:=\s*)?('(?:[^'\\]|''|\\.)*'|[^\s#']+)"
    $value = $null
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        $m = [regex]::Match($line, $pattern)
        if (-not $m.Success) { continue }
        if ($m.Groups[1].Value -ine $Name) { continue }
        $raw = $m.Groups[2].Value
        if ($raw.Length -ge 2 -and $raw.StartsWith("'") -and $raw.EndsWith("'")) {
            $raw = $raw.Substring(1, $raw.Length - 2)
            $raw = $raw -replace "''", "'"
            $raw = [regex]::Replace($raw, '\\(.)', '$1')
        }
        $value = $raw
    }
    return $value
}

# Returns the names among hba_file and ident_file that postgresql.conf,
# postgresql.auto.conf or a file they include sets. Fails closed: when the
# files cannot be read as PostgreSQL would, both names are returned.
function Test-PgConfOverride {
    param([Parameter(Mandatory)][string] $DataDir)

    $watched = @('hba_file', 'ident_file')
    $mainConf = [IO.Path]::Combine($DataDir, 'postgresql.conf')
    if (-not (Test-Path -LiteralPath $mainConf -PathType Leaf)) {
        Write-Log "No postgresql.conf in '$DataDir'. PostgreSQL reads its settings from elsewhere, so pg_hba.conf and pg_ident.conf in the data directory may not be the live files." WARN
        return $watched
    }
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $bom = "$([char]0xEF)$([char]0xBB)$([char]0xBF)"
    $found = New-Object System.Collections.ArrayList
    $seen = @{}
    $pending = New-Object System.Collections.ArrayList
    [void]$pending.Add([pscustomobject]@{ Path = $mainConf; Depth = 0 })
    $autoConf = [IO.Path]::Combine($DataDir, 'postgresql.auto.conf')
    if (Test-Path -LiteralPath $autoConf -PathType Leaf) { [void]$pending.Add([pscustomobject]@{ Path = $autoConf; Depth = 0 }) }

    while ($pending.Count -gt 0) {
        $item = $pending[0]
        $pending.RemoveAt(0)
        $full = [IO.Path]::GetFullPath($item.Path)
        $fileKey = $full.ToLowerInvariant()
        if ($seen.ContainsKey($fileKey)) { continue }
        $seen[$fileKey] = $true
        try {
            $text = $latin1.GetString([IO.File]::ReadAllBytes($full))
        } catch {
            Write-Log "Could not read '$full': $($_.Exception.Message). Treating hba_file and ident_file as overridden." WARN
            return $watched
        }
        if ($text.StartsWith($bom)) { $text = $text.Substring(3) }
        $lines = @($text -split "`n" | ForEach-Object { $_.TrimEnd([char]13) })
        foreach ($settingName in $watched) {
            if ($null -ne (Get-PgConfSetting -Lines $lines -Name $settingName) -and -not $found.Contains($settingName)) {
                Write-Log "'$full' sets $settingName." WARN
                [void]$found.Add($settingName)
            }
        }
        $folder = [IO.Path]::GetDirectoryName($full)
        foreach ($line in $lines) {
            if ($line -notmatch '^\s*include') { continue }
            foreach ($directive in @('include', 'include_if_exists', 'include_dir')) {
                $target = Get-PgConfSetting -Lines @($line) -Name $directive
                if ($null -eq $target) { continue }
                if ($item.Depth -ge 10) {
                    Write-Log "Configuration files included from '$full' nest more than 10 deep. Treating hba_file and ident_file as overridden." WARN
                    return $watched
                }
                $targetPath = $target -replace '/', '\'
                if (-not [IO.Path]::IsPathRooted($targetPath)) { $targetPath = [IO.Path]::Combine($folder, $targetPath) }
                if ($directive -eq 'include_dir') {
                    if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
                        Write-Log "Folder '$targetPath' named by include_dir in '$full' does not exist. Treating hba_file and ident_file as overridden." WARN
                        return $watched
                    }
                    foreach ($f in @(Get-ChildItem -LiteralPath $targetPath -File | Where-Object { $_.Name -like '*.conf' -and $_.Name -notlike '.*' } | Sort-Object Name)) {
                        [void]$pending.Add([pscustomobject]@{ Path = $f.FullName; Depth = $item.Depth + 1 })
                    }
                } elseif (Test-Path -LiteralPath $targetPath -PathType Leaf) {
                    [void]$pending.Add([pscustomobject]@{ Path = $targetPath; Depth = $item.Depth + 1 })
                } elseif ($directive -eq 'include') {
                    Write-Log "File '$targetPath' named by include in '$full' does not exist. Treating hba_file and ident_file as overridden." WARN
                    return $watched
                }
            }
        }
    }
    return @($watched | Where-Object { $found.Contains($_) })
}
# Which loopback addresses listen on the port. A wildcard listener counts for its
# family: 0.0.0.0 for 127.0.0.1 and :: for ::1. Output order: 127.0.0.1, ::1.
function Select-ListeningLoopback {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]] $Listeners,
        [Parameter(Mandatory)][int] $Port
    )

    $v4 = $false
    $v6 = $false
    foreach ($l in @($Listeners)) {
        if ($null -eq $l) { continue }
        $localPort = Get-CfgValue -Object $l -Name 'LocalPort'
        if ($null -eq $localPort -or [int]$localPort -ne $Port) { continue }
        $address = "$(Get-CfgValue -Object $l -Name 'LocalAddress')".Trim()
        if ($address -eq '127.0.0.1' -or $address -eq '0.0.0.0') { $v4 = $true }
        elseif ($address -eq '::1' -or $address -eq '::') { $v6 = $true }
    }
    $out = @()
    if ($v4) { $out += '127.0.0.1' }
    if ($v6) { $out += '::1' }
    return $out
}

function Get-ListeningLoopback {
    param([Parameter(Mandatory)][int] $Port)

    $listeners = @()
    try {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    } catch {
        Write-Log "Could not list TCP listeners on port ${Port}: $($_.Exception.Message)" WARN
        $listeners = @()
    }
    return Select-ListeningLoopback -Listeners $listeners -Port $Port
}
#endregion PgDiscovery

#region Names
# SID -> the exact LSA name, split at the backslash. PostgreSQL builds the SSPI
# name from the same LookupAccountSid call, so the result matches what it sees.
function Get-NtAccountParts {
    param([Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier] $Sid)

    $nt = $Sid.Translate([System.Security.Principal.NTAccount]).Value
    $i = $nt.IndexOf('\')
    if ($i -lt 0) { return [pscustomobject]@{ Domain = ''; Name = $nt } }
    return [pscustomobject]@{ Domain = $nt.Substring(0, $i); Name = $nt.Substring($i + 1) }
}

# pg_ident.conf compares SSPI users as name@domain (include_realm=1, compat_realm=1).
function ConvertTo-SspiMapName {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Domain,
        [Parameter(Mandatory)][string] $Name
    )
    return '{0}@{1}' -f $Name, $Domain
}

function Get-SspiMapNameFromSid {
    param([Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier] $Sid)

    $parts = Get-NtAccountParts -Sid $Sid
    return ConvertTo-SspiMapName -Domain $parts.Domain -Name $parts.Name
}
# True when every character is printable ASCII (0x20-0x7E). New pg_ident lines must be ASCII.
function Test-AsciiText {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    return [regex]::IsMatch($Text, '\A[\x20-\x7E]*\z')
}

# The English SYSTEM name that Veeam writes, and the name this Windows really uses.
function Get-SystemMapNames {
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $translated = Get-SspiMapNameFromSid -Sid $systemSid
    return [pscustomobject]@{
        English    = 'SYSTEM@NT AUTHORITY'
        Translated = $translated
        IsAscii    = (Test-AsciiText -Text $translated)
    }
}
# Turns a Win32_Service StartName into a pg_ident name. The translator takes
# DOMAIN\x or a UPN and returns name@domain; tests pass a fake one.
function Resolve-ServiceStartName {
    param(
        [AllowNull()][AllowEmptyString()][string] $StartName,
        [Parameter(Mandatory)][string] $ComputerName,
        [scriptblock] $Translator
    )

    $name = "$StartName".Trim()
    if (-not $name -or (@('LocalSystem', 'NT AUTHORITY\SYSTEM', '.\LocalSystem') -contains $name)) {
        return [pscustomobject]@{ Kind = 'LOCALSYSTEM'; MapName = $null; Detail = "'$name' is LocalSystem" }
    }
    $builtIn = @('NT AUTHORITY\NetworkService', 'NT AUTHORITY\Network Service', 'NT AUTHORITY\LocalService', 'NT AUTHORITY\Local Service')
    if (($builtIn -contains $name) -or $name.EndsWith('$')) {
        return [pscustomobject]@{ Kind = 'UNSUPPORTED'; MapName = $null; Detail = "Service account '$name' is not supported. NetworkService, LocalService and gMSA accounts cannot be mapped." }
    }
    $target = $name
    if ($target.StartsWith('.\')) { $target = $ComputerName + '\' + $target.Substring(2) }
    if (-not $Translator) {
        $Translator = {
            param([string] $AccountName)
            $account = New-Object System.Security.Principal.NTAccount($AccountName)
            $accountSid = $account.Translate([System.Security.Principal.SecurityIdentifier])
            Get-SspiMapNameFromSid -Sid $accountSid
        }
    }
    try {
        $mapName = "$(& $Translator $target)".Trim()
    } catch {
        return [pscustomobject]@{ Kind = 'UNRESOLVED'; MapName = $null; Detail = "Service account '$name' could not be resolved: $($_.Exception.Message)" }
    }
    if (-not $mapName) {
        return [pscustomobject]@{ Kind = 'UNRESOLVED'; MapName = $null; Detail = "Service account '$name' resolved to an empty name." }
    }
    return [pscustomobject]@{ Kind = 'ACCOUNT'; MapName = $mapName; Detail = "'$name' maps to '$mapName'" }
}

# pg_ident names of every Veeam* service that does not run as LocalSystem.
# Unresolved holds each StartName that cannot be mapped (spec 7.3: SERVICE_ACCOUNT_UNRESOLVED).
function Get-VeeamServiceAccountNames {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]] $Services,
        [string] $ComputerName = $env:COMPUTERNAME,
        [scriptblock] $Translator
    )

    $mapNames = New-Object System.Collections.ArrayList
    $unresolved = New-Object System.Collections.ArrayList
    if (-not $PSBoundParameters.ContainsKey('Services')) {
        try {
            $Services = @(Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'Veeam%'" -ErrorAction Stop)
        } catch {
            Write-Log "Could not list the Veeam services: $($_.Exception.Message)" WARN
            [void]$unresolved.Add("(Veeam service list unavailable: $($_.Exception.Message))")
            return [pscustomobject]@{ MapNames = [string[]]@(); Unresolved = [string[]]@($unresolved) }
        }
    }
    $resolveArgs = @{ ComputerName = $ComputerName }
    if ($Translator) { $resolveArgs['Translator'] = $Translator }

    $rows = @()
    foreach ($s in @($Services)) {
        if ($null -eq $s) { continue }
        $serviceName = "$(Get-CfgValue -Object $s -Name 'Name')"
        if ($serviceName -notlike 'Veeam*') { continue }
        $rows += [pscustomobject]@{ Name = $serviceName; StartName = "$(Get-CfgValue -Object $s -Name 'StartName')" }
    }
    foreach ($row in @($rows | Sort-Object Name)) {
        $res = Resolve-ServiceStartName -StartName $row.StartName @resolveArgs
        if ($res.Kind -eq 'LOCALSYSTEM') { continue }
        if ($res.Kind -eq 'ACCOUNT') {
            Write-Log "Service $($row.Name) runs as '$($row.StartName)' (pg_ident name '$($res.MapName)')."
            if (-not (@($mapNames) -contains $res.MapName)) { [void]$mapNames.Add($res.MapName) }
            continue
        }
        Write-Log "Service $($row.Name): $($res.Detail)" WARN
        if (-not (@($unresolved) -contains $row.StartName)) { [void]$unresolved.Add($row.StartName) }
    }
    return [pscustomobject]@{ MapNames = [string[]]@($mapNames); Unresolved = [string[]]@($unresolved) }
}
#endregion Names

#region Account
function Get-ServiceAccountInfo {
    # Reads a local account through ADSI WinNT. The LocalAccounts read cmdlets are not used.
    # Exists=$true with IsUser=$false means a local group has the name (SVC_NAME_IN_USE).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Name)

    # True when the error, or any exception inside it, has one of the HRESULTs (8 hex digits).
    # PowerShell wraps ADSI errors: the COMException sits inside an ExtendedTypeSystemException.
    $hasHResult = {
        param($ErrorRecord, [string[]] $Codes)
        $ex = $ErrorRecord.Exception
        $depth = 0
        while ($null -ne $ex -and $depth -lt 10) {
            if ($Codes -contains ('{0:X8}' -f $ex.HResult)) { return $true }
            $ex = $ex.InnerException
            $depth++
        }
        return $false
    }

    $info = [pscustomobject]@{
        Exists            = $false
        IsUser            = $false
        Sid               = $null
        UserFlags         = 0
        HasExpirationDate = $false
        IsLocked          = $false
        PasswordExpired   = $false
        IsAdmin           = $false
        MapName           = ''
    }
    $computer = $env:COMPUTERNAME

    $user = New-Object System.DirectoryServices.DirectoryEntry("WinNT://$computer/$Name,user")
    try {
        $bound = $false
        try {
            $user.RefreshCache()
            $bound = $true
        } catch {
            # 0x800708AD NERR_UserNotFound: no user has this name (a group with the name gives the same code).
            if (-not (& $hasHResult $_ @('800708AD'))) { throw }
        }
        if ($bound) {
            $flags = 0
            $rawFlags = $user.Properties['UserFlags'].Value
            if ($null -ne $rawFlags) { $flags = [int]$rawFlags }
            $sidBytes = [byte[]]$user.Properties['objectSid'].Value
            $info.Exists = $true
            $info.IsUser = $true
            $info.UserFlags = $flags
            $info.Sid = New-Object System.Security.Principal.SecurityIdentifier($sidBytes, 0)
            # Never read AccountExpirationDate itself: it is absent (and throws under StrictMode)
            # when the account never expires.
            $info.HasExpirationDate = [bool]$user.Properties.Contains('AccountExpirationDate')
            $rawExpired = $user.Properties['PasswordExpired'].Value
            $info.PasswordExpired = (($null -ne $rawExpired) -and ([int]$rawExpired -ne 0))
            $locked = (($flags -band 0x10) -ne 0)
            if (-not $locked) {
                try { $locked = [bool]$user.InvokeGet('IsAccountLocked') } catch { $locked = $false }
            }
            $info.IsLocked = $locked
        }
    } finally {
        # On an entry that never bound, the ADSI adapter throws even from Dispose().
        try { $user.Dispose() } catch { }
    }

    if ($info.Exists) {
        $info.IsAdmin = [bool](Test-AdministratorsMember -MemberSid $info.Sid)
        try {
            $info.MapName = [string](Get-SspiMapNameFromSid -Sid $info.Sid)
        } catch {
            Write-Log -Message ('Cannot translate the SID of account {0}: {1}' -f $Name, (Format-ShortText -Text $_.Exception.Message)) -Level 'WARN'
        }
        return $info
    }

    $group = New-Object System.DirectoryServices.DirectoryEntry("WinNT://$computer/$Name,group")
    try {
        try {
            $group.RefreshCache()
            $info.Exists = $true
            $info.IsUser = $false
        } catch {
            # 0x800708AC NERR_GroupNotFound: the name is free.
            if (-not (& $hasHResult $_ @('800708AC'))) { throw }
        }
    } finally {
        try { $group.Dispose() } catch { }
    }
    return $info
}

function Get-ServiceAccountStatus {
    # Pure. Turns a Get-ServiceAccountInfo result into one status and every matching issue code.
    # UserFlags: 0x2 disabled, 0x10 locked out, 0x40 user cannot change password,
    # 0x10000 password never expires. An expiry date (HasExpirationDate) is flag drift.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object] $Info)

    $exists = [bool](Get-CfgValue -Object $Info -Name 'Exists' -Default $false)
    $isUser = [bool](Get-CfgValue -Object $Info -Name 'IsUser' -Default $false)
    if (-not $exists) {
        return [pscustomobject]@{ Status = 'MISSING'; Codes = [string[]]@('SVC_ACCOUNT_MISSING'); NeedsAdmin = $false; NeedsFlags = $false }
    }
    if (-not $isUser) {
        return [pscustomobject]@{ Status = 'NAME_IN_USE'; Codes = [string[]]@('SVC_NAME_IN_USE'); NeedsAdmin = $false; NeedsFlags = $false }
    }

    $flags = [int](Get-CfgValue -Object $Info -Name 'UserFlags' -Default 0)
    $isAdmin = [bool](Get-CfgValue -Object $Info -Name 'IsAdmin' -Default $false)
    $hasExpiry = [bool](Get-CfgValue -Object $Info -Name 'HasExpirationDate' -Default $false)
    $isLocked = ([bool](Get-CfgValue -Object $Info -Name 'IsLocked' -Default $false)) -or (($flags -band 0x10) -ne 0)
    $pwExpired = [bool](Get-CfgValue -Object $Info -Name 'PasswordExpired' -Default $false)
    $needsFlags = ((($flags -band 0x10000) -eq 0) -or (($flags -band 0x40) -eq 0) -or $hasExpiry)

    # In status precedence order.
    $checks = @(
        @{ Hit = (-not $isAdmin);            Status = 'NOT_ADMIN';   Code = 'SVC_NOT_ADMIN' },
        @{ Hit = $needsFlags;                Status = 'FLAGS_DRIFT'; Code = 'SVC_FLAGS_DRIFT' },
        @{ Hit = (($flags -band 0x2) -ne 0); Status = 'DISABLED';    Code = 'SVC_DISABLED' },
        @{ Hit = $isLocked;                  Status = 'LOCKED_OUT';  Code = 'SVC_LOCKED_OUT' },
        @{ Hit = $pwExpired;                 Status = 'EXPIRED';     Code = 'SVC_PASSWORD_EXPIRED' }
    )
    $status = 'OK'
    $codes = New-Object System.Collections.Generic.List[string]
    foreach ($check in $checks) {
        if ($check.Hit) {
            if ($status -eq 'OK') { $status = $check.Status }
            $codes.Add($check.Code)
        }
    }
    return [pscustomobject]@{
        Status     = $status
        Codes      = [string[]]$codes.ToArray()
        NeedsAdmin = (-not $isAdmin)
        NeedsFlags = $needsFlags
    }
}

function Test-AdministratorsMember {
    # Membership of local Administrators (S-1-5-32-544) by SID, through ADSI.
    # The LocalAccounts member-list cmdlet is not used: it fails on orphaned SIDs. A member whose SID cannot be read is skipped.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Security.Principal.SecurityIdentifier] $MemberSid)

    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $groupName = (Get-NtAccountParts -Sid $adminsSid).Name
    $group = New-Object System.DirectoryServices.DirectoryEntry("WinNT://$($env:COMPUTERNAME)/$groupName,group")
    try {
        foreach ($member in @($group.Invoke('Members'))) {
            try {
                $bytes = [byte[]]$member.GetType().InvokeMember('objectSid', [System.Reflection.BindingFlags]::GetProperty, $null, $member, $null)
                $sid = New-Object System.Security.Principal.SecurityIdentifier($bytes, 0)
                if ($sid.Equals($MemberSid)) { return $true }
            } catch {
                # Skip a member whose SID cannot be read; never fail the whole check.
            }
        }
    } finally {
        try { $group.Dispose() } catch { }
    }
    return $false
}

function Add-AdministratorsMember {
    # Adds the account to local Administrators by SID. "Already a member" counts as success.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Security.Principal.SecurityIdentifier] $UserSid,
        [Parameter(Mandatory = $true)][string] $UserName
    )
    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')

    if (Get-Command -Name 'Add-LocalGroupMember' -ErrorAction SilentlyContinue) {
        try {
            Add-LocalGroupMember -SID $adminsSid -Member $UserSid.Value -ErrorAction Stop
        } catch {
            $isMember = $false
            $ex = $_.Exception
            $depth = 0
            while ($null -ne $ex -and $depth -lt 10) {
                if ($ex.GetType().Name -eq 'MemberExistsException' -or $ex.Message -match 'already a member') { $isMember = $true }
                $ex = $ex.InnerException
                $depth++
            }
            if (-not $isMember) { throw }
        }
        return
    }

    # ADSI fallback when the LocalAccounts module is not present.
    $groupName = (Get-NtAccountParts -Sid $adminsSid).Name
    $group = New-Object System.DirectoryServices.DirectoryEntry("WinNT://$($env:COMPUTERNAME)/$groupName,group")
    try {
        $null = $group.Invoke('Add', [object[]]@("WinNT://$($env:COMPUTERNAME)/$UserName,user"))
    } catch {
        $ex = $_.Exception
        $depth = 0
        while ($null -ne $ex -and $depth -lt 10) {
            # 0x80070562 ERROR_MEMBER_IN_ALIAS: already a member.
            if (('{0:X8}' -f $ex.HResult) -eq '80070562') { return }
            $ex = $ex.InnerException
            $depth++
        }
        throw
    } finally {
        try { $group.Dispose() } catch { }
    }
}

function Read-ServiceAccountPassword {
    # Reads the password from the process environment once, removes the variable at once,
    # and returns a read-only SecureString ($null when the variable is missing or empty).
    # The plain text is never logged, written to a file or passed to a program.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $EnvVarName)

    $raw = [System.Environment]::GetEnvironmentVariable($EnvVarName, 'Process')
    [System.Environment]::SetEnvironmentVariable($EnvVarName, $null, 'Process')
    if ([string]::IsNullOrEmpty($raw)) { return $null }
    $chars = $raw.ToCharArray()
    $raw = $null
    $secure = New-Object System.Security.SecureString
    try {
        foreach ($ch in $chars) { $secure.AppendChar($ch) }
    } finally {
        [System.Array]::Clear($chars, 0, $chars.Length)
    }
    $secure.MakeReadOnly()
    return $secure
}

function ConvertTo-AccountIssueCode {
    # Maps a LocalAccounts error to an issue code by exception TYPE NAME (inner exceptions included).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord] $ErrorRecord)

    $ex = $ErrorRecord.Exception
    $depth = 0
    while ($null -ne $ex -and $depth -lt 10) {
        switch ($ex.GetType().Name) {
            'InvalidPasswordException' { return 'SVC_PASSWORD_POLICY' }
            'NameInUseException'       { return 'SVC_NAME_IN_USE' }
            'UserExistsException'      { return 'SVC_NAME_IN_USE' }
        }
        $ex = $ex.InnerException
        $depth++
    }
    return $null
}

function New-ServiceAccount {
    # Creates the local account with the three flags. A password-policy failure or a name clash
    # comes back as IssueCode, and nothing is created. Any other error is thrown.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][System.Security.SecureString] $Password,
        [Parameter(Mandatory = $true)][string] $Description
    )
    if ($Description.Length -gt 48) { $Description = $Description.Substring(0, 48) }

    if (Get-Command -Name 'New-LocalUser' -ErrorAction SilentlyContinue) {
        try {
            $null = New-LocalUser -Name $Name -Password $Password -Description $Description -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires -ErrorAction Stop
        } catch {
            # New-LocalUser deletes the half-made account itself when the policy rejects the password.
            $code = ConvertTo-AccountIssueCode -ErrorRecord $_
            if ($code) { return [pscustomobject]@{ Created = $false; IssueCode = [string]$code } }
            throw
        }
        return [pscustomobject]@{ Created = $true; IssueCode = '' }
    }

    # ADSI fallback (no LocalAccounts module). NetUserAdd runs at CommitChanges with the password,
    # description and flags together, and creates nothing when the password fails the policy.
    $hresultCodes = @{
        '800708C5' = 'SVC_PASSWORD_POLICY'   # NERR_PasswordTooShort: the password fails the policy
        '8007052D' = 'SVC_PASSWORD_POLICY'   # ERROR_PASSWORD_RESTRICTION
        '800708B0' = 'SVC_NAME_IN_USE'       # NERR_UserExists
        '800708AF' = 'SVC_NAME_IN_USE'       # NERR_GroupExists
        '80070563' = 'SVC_NAME_IN_USE'       # ERROR_ALIAS_EXISTS: a local group has the name
        '80070524' = 'SVC_NAME_IN_USE'       # ERROR_USER_EXISTS
    }
    $computer = New-Object System.DirectoryServices.DirectoryEntry("WinNT://$($env:COMPUTERNAME),computer")
    $user = $null
    $plain = $null
    $bstr = [System.IntPtr]::Zero
    try {
        $user = $computer.Children.Add($Name, 'user')
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $null = $user.Invoke('SetPassword', [object[]]@($plain))
        $plain = $null
        $null = $user.Invoke('Put', [object[]]@('Description', $Description))
        # 0x10241 = script + normal account + user cannot change password + password never expires.
        # A new WinNT account has no expiry date, so the account never expires.
        $null = $user.Invoke('Put', [object[]]@('UserFlags', 0x10241))
        $user.CommitChanges()
        return [pscustomobject]@{ Created = $true; IssueCode = '' }
    } catch {
        $ex = $_.Exception
        $depth = 0
        while ($null -ne $ex -and $depth -lt 10) {
            $hex = '{0:X8}' -f $ex.HResult
            if ($hresultCodes.ContainsKey($hex)) { return [pscustomobject]@{ Created = $false; IssueCode = [string]$hresultCodes[$hex] } }
            $ex = $ex.InnerException
            $depth++
        }
        throw
    } finally {
        $plain = $null
        if ($bstr -ne [System.IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($null -ne $user) { try { $user.Dispose() } catch { } }
        try { $computer.Dispose() } catch { }
    }
}

function Set-ServiceAccountFlags {
    # Sets: password never expires, user cannot change the password, account never expires.
    # Never touches the password, the enabled state or a lockout.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Name)

    if (Get-Command -Name 'Set-LocalUser' -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name $Name -PasswordNeverExpires $true -UserMayChangePassword $false -AccountNeverExpires -ErrorAction Stop
        return
    }

    # ADSI fallback: sets the two UserFlags bits. WinNT has no clean way to clear an expiry
    # date, so that drift stays and the re-read reports it.
    $user = New-Object System.DirectoryServices.DirectoryEntry("WinNT://$($env:COMPUTERNAME)/$Name,user")
    try {
        $user.RefreshCache()
        $flags = [int]$user.Properties['UserFlags'].Value
        $user.Properties['UserFlags'].Value = ($flags -bor 0x40 -bor 0x10000)
        $user.CommitChanges()
        if ($user.Properties.Contains('AccountExpirationDate')) {
            Write-Log -Message ('Account {0} has an expiry date. Without the LocalAccounts module the script cannot clear it.' -f $Name) -Level 'WARN'
        }
    } finally {
        try { $user.Dispose() } catch { }
    }
}

function Invoke-ServiceAccountStep {
    # Spec 7.2. Reads the account, fixes what the mode allows, and adds one issue (exit 5) for
    # each problem that remains. BlocksDb is true when the account is missing, the name is a
    # group, or the account is not in Administrators after this step.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Config,
        [Parameter(Mandatory = $true)][bool] $Apply,
        [Parameter(Mandatory = $true)][bool] $CreateRequested
    )
    $name = [string]$Config['ServiceAccountName']
    if ([string]::IsNullOrEmpty($name)) { $name = 'svc_veeam' }
    $description = [string]$Config['ServiceAccountDescription']
    if ([string]::IsNullOrEmpty($description)) { $description = 'Veeam maintenance account (PostgreSQL SSPI map)' }
    $envVar = [string]$Config['PasswordEnvVar']
    if ([string]::IsNullOrEmpty($envVar)) { $envVar = 'VEEAM_SVC_PASSWORD' }
    $createAction = "Set RMM secure variable $envVar and re-run with -CreateServiceAccount"
    $fix = ($Apply -or $CreateRequested)

    Write-Log -Message ('Checking local account {0}.' -f $name) -Level 'INFO'
    # Read and clear the variable in every mode, so the secret never stays in this process's
    # environment, where every child process (psql.exe, reg.exe) would inherit it.
    $password = Read-ServiceAccountPassword -EnvVarName $envVar
    try {
        $info = Get-ServiceAccountInfo -Name $name
        $status = Get-ServiceAccountStatus -Info $info

        if ($status.Status -eq 'MISSING') {
            if (-not $CreateRequested) {
                Add-RunIssue -Code 'SVC_ACCOUNT_MISSING' -ExitCode 5 -Detail ('Local account {0} does not exist. No database change was made.' -f $name) -Action $createAction
                Write-Log -Message ('Account {0} is missing.' -f $name) -Level 'WARN'
                return [pscustomobject]@{ Status = 'MISSING'; Info = $info; BlocksDb = $true }
            }
            if ($null -eq $password) {
                Add-RunIssue -Code 'SVC_PASSWORD_REQUIRED' -ExitCode 5 -Detail ('-CreateServiceAccount was given, but environment variable {0} is empty. Account {1} was not created and no database change was made.' -f $envVar, $name) -Action $createAction
                Write-Log -Message ('Account {0} is missing and {1} is empty; nothing was created.' -f $name, $envVar) -Level 'WARN'
                return [pscustomobject]@{ Status = 'MISSING'; Info = $info; BlocksDb = $true }
            }
            $created = New-ServiceAccount -Name $name -Password $password -Description $description
            if (-not $created.Created) {
                $code = [string]$created.IssueCode
                if ($code -eq 'SVC_PASSWORD_POLICY') {
                    Add-RunIssue -Code 'SVC_PASSWORD_POLICY' -ExitCode 5 -Detail ('The password in {0} does not meet the Windows password policy. Account {1} was not created.' -f $envVar, $name) -Action ('Set a {0} value that meets the Windows password policy, then re-run with -CreateServiceAccount' -f $envVar)
                    Write-Log -Message ('Account {0} was not created: the password does not meet the password policy.' -f $name) -Level 'WARN'
                    return [pscustomobject]@{ Status = 'MISSING'; Info = $info; BlocksDb = $true }
                }
                if ($code -eq 'SVC_NAME_IN_USE') {
                    Add-RunIssue -Code 'SVC_NAME_IN_USE' -ExitCode 5 -Detail ('Account {0} was not created: the name is already in use.' -f $name) -Action ('Rename or remove the local group or account named {0}, then re-run' -f $name)
                    Write-Log -Message ('Account {0} was not created: the name is already in use.' -f $name) -Level 'WARN'
                    return [pscustomobject]@{ Status = 'NAME_IN_USE'; Info = $info; BlocksDb = $true }
                }
                Add-RunIssue -Code 'SVC_ACCOUNT_MISSING' -ExitCode 5 -Detail ('Account {0} could not be created.' -f $name) -Action $createAction
                return [pscustomobject]@{ Status = 'MISSING'; Info = $info; BlocksDb = $true }
            }
            Write-Log -Message ('Created local account {0}.' -f $name) -Level 'OK'
            # Never trust the call: read the account again.
            $info = Get-ServiceAccountInfo -Name $name
            $status = Get-ServiceAccountStatus -Info $info
            if ($status.Status -eq 'MISSING') {
                Add-RunIssue -Code 'SVC_ACCOUNT_MISSING' -ExitCode 5 -Detail ('Account {0} was created but cannot be read back.' -f $name) -Action ('Check local account {0} by hand, then re-run' -f $name)
                return [pscustomobject]@{ Status = 'MISSING'; Info = $info; BlocksDb = $true }
            }
        }

        if ($status.Status -eq 'NAME_IN_USE') {
            Add-RunIssue -Code 'SVC_NAME_IN_USE' -ExitCode 5 -Detail ('The name {0} belongs to a local group, so the account cannot exist. No database change was made.' -f $name) -Action ('Rename or remove the local group named {0}, then re-run' -f $name)
            Write-Log -Message ('The name {0} belongs to a local group.' -f $name) -Level 'WARN'
            return [pscustomobject]@{ Status = 'NAME_IN_USE'; Info = $info; BlocksDb = $true }
        }

        $adminFailure = ''
        $flagsFailure = ''
        if ($fix -and ($status.NeedsAdmin -or $status.NeedsFlags)) {
            if ($status.NeedsAdmin) {
                try {
                    Add-AdministratorsMember -UserSid (Get-CfgValue -Object $info -Name 'Sid') -UserName $name
                    Write-Log -Message ('Added {0} to local Administrators.' -f $name) -Level 'OK'
                } catch {
                    $adminFailure = Format-ShortText -Text $_.Exception.Message -MaxLength 300
                    Write-Log -Message ('Could not add {0} to local Administrators: {1}' -f $name, $adminFailure) -Level 'WARN'
                }
            }
            if ($status.NeedsFlags) {
                try {
                    Set-ServiceAccountFlags -Name $name
                    Write-Log -Message ('Set the account flags of {0}.' -f $name) -Level 'OK'
                } catch {
                    $flagsFailure = Format-ShortText -Text $_.Exception.Message -MaxLength 300
                    Write-Log -Message ('Could not set the account flags of {0}: {1}' -f $name, $flagsFailure) -Level 'WARN'
                }
            }
            # Never trust the calls: read the account again and check every item by SID.
            $info = Get-ServiceAccountInfo -Name $name
            $status = Get-ServiceAccountStatus -Info $info
        }

        $flags = [int](Get-CfgValue -Object $info -Name 'UserFlags' -Default 0)
        foreach ($code in @($status.Codes)) {
            $detail = ''
            $action = ''
            switch ($code) {
                'SVC_NOT_ADMIN' {
                    $detail = "Account $name is not a member of local Administrators (S-1-5-32-544). No database change was made."
                    if ($adminFailure) { $detail += " Adding it failed: $adminFailure" }
                    if ($fix) { $action = "Add $name to local Administrators by hand, and check for a Group Policy (Restricted Groups) that removes it" }
                    else { $action = "Re-run with -Apply to add $name to local Administrators" }
                }
                'SVC_FLAGS_DRIFT' {
                    $drift = New-Object System.Collections.Generic.List[string]
                    if (($flags -band 0x10000) -eq 0) { $drift.Add('the password expires') }
                    if (($flags -band 0x40) -eq 0) { $drift.Add('the user can change the password') }
                    if ([bool](Get-CfgValue -Object $info -Name 'HasExpirationDate' -Default $false)) { $drift.Add('the account has an expiry date') }
                    $detail = "Account $name flag drift: " + ($drift -join ', ') + '.'
                    if ($flagsFailure) { $detail += " Setting the flags failed: $flagsFailure" }
                    if ($fix) { $action = "Set the $name flags by hand: password never expires, user cannot change password, account never expires" }
                    else { $action = "Re-run with -Apply to set the $name account flags" }
                }
                'SVC_DISABLED' {
                    $detail = "Account $name is disabled. The script never enables it."
                    $action = "Check why $name is disabled, and enable it by hand if it should be in use"
                }
                'SVC_LOCKED_OUT' {
                    $detail = "Account $name is locked out. The script never unlocks it."
                    $action = "Check the failed logons of $name, then unlock it by hand"
                }
                'SVC_PASSWORD_EXPIRED' {
                    $detail = "The password of $name has expired or must change at next logon. The script never resets it."
                    $action = "Reset the $name password by hand from the vault"
                }
                'SVC_ACCOUNT_MISSING' {
                    $detail = "Local account $name does not exist. No database change was made."
                    $action = $createAction
                }
                'SVC_NAME_IN_USE' {
                    $detail = "The name $name belongs to a local group, so the account cannot exist. No database change was made."
                    $action = "Rename or remove the local group named $name, then re-run"
                }
            }
            Add-RunIssue -Code $code -ExitCode 5 -Detail $detail -Action $action
        }

        $sidText = ''
        $sidValue = Get-CfgValue -Object $info -Name 'Sid'
        if ($null -ne $sidValue) { $sidText = [string]$sidValue }
        $mapName = [string](Get-CfgValue -Object $info -Name 'MapName' -Default '')
        $level = 'OK'
        if ($status.Status -ne 'OK') { $level = 'WARN' }
        Write-Log -Message ('Account {0}: {1} (SID {2}, map name {3}).' -f $name, $status.Status, $sidText, $mapName) -Level $level

        $isAdmin = [bool](Get-CfgValue -Object $info -Name 'IsAdmin' -Default $false)
        $blocks = (($status.Status -eq 'MISSING') -or ($status.Status -eq 'NAME_IN_USE') -or (-not $isAdmin))
        return [pscustomobject]@{ Status = [string]$status.Status; Info = $info; BlocksDb = [bool]$blocks }
    } finally {
        if ($null -ne $password) { $password.Dispose() }
    }
}
#endregion Account

#region ConfFiles
# Latin-1 (code page 28591) maps every byte 0-255 to the char with the same number and
# back, so text work on pg_hba.conf / pg_ident.conf never changes a byte it does not
# touch (CP1252 or UTF-8 bytes in a comment survive unchanged).
function ConvertFrom-Latin1Bytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    return $latin1.GetString($Bytes)
}

# The reverse of ConvertFrom-Latin1Bytes. A char above U+00FF has no Latin-1 byte, so
# the encoder throws instead of writing '?' into a config file. The leading comma
# returns the byte[] as one object; PowerShell would otherwise unroll it byte by byte.
function ConvertTo-Latin1Bytes {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    $latin1 = [System.Text.Encoding]::GetEncoding(28591,
        [System.Text.EncoderFallback]::ExceptionFallback,
        [System.Text.DecoderFallback]::ExceptionFallback)
    $bytes = $latin1.GetBytes($Text)
    return ,$bytes
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
    } finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

# Reads a config file as bytes. Text is the Latin-1 text of the bytes after a UTF-8
# BOM (the BOM is never written back). LineEnding is CRLF when the first line break
# is CRLF, else LF. Sddl is recorded so every later write can prove the ACL is kept.
function Read-ConfFile {
    param([Parameter(Mandatory = $true)][string] $Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $body = $bytes
    if ($hadBom) {
        $body = New-Object byte[] ($bytes.Length - 3)
        [System.Array]::Copy($bytes, 3, $body, 0, $body.Length)
    }
    $text = ConvertFrom-Latin1Bytes -Bytes $body
    $lineEnding = "`n"
    $firstLf = $text.IndexOf([char]10)
    if ($firstLf -gt 0 -and $text[$firstLf - 1] -eq [char]13) { $lineEnding = "`r`n" }
    $sddl = (Get-Acl -LiteralPath $full).Sddl
    return [pscustomobject]@{
        Path       = $full
        Bytes      = $bytes
        Text       = $text
        LineEnding = $lineEnding
        HadBom     = $hadBom
        Sddl       = $sddl
    }
}

# Splits on LF and removes one trailing CR from each line. A final line break does not
# make an empty last line, and empty text gives no lines. Callers wrap the result in
# @(), because PowerShell returns a single line as a plain string.
function Split-ConfLines {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    if ($Text.Length -eq 0) { return }
    $parts = $Text.Split([char[]]@([char]10))
    $count = $parts.Length
    if ($Text[$Text.Length - 1] -eq [char]10) { $count-- }
    $lines = New-Object string[] $count
    for ($i = 0; $i -lt $count; $i++) {
        $line = $parts[$i]
        if ($line.Length -gt 0 -and $line[$line.Length - 1] -eq [char]13) {
            $line = $line.Substring(0, $line.Length - 1)
        }
        $lines[$i] = $line
    }
    return $lines
}

# Joins lines with LineEnding and ends the text with one LineEnding. No lines give an
# empty text, so an empty file survives Split-ConfLines + Join-ConfLines unchanged.
function Join-ConfLines {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines,
        [Parameter(Mandatory = $true)][string] $LineEnding
    )
    if ($LineEnding -cne "`n" -and $LineEnding -cne "`r`n") {
        throw 'Join-ConfLines: LineEnding must be LF or CRLF.'
    }
    if ($Lines.Length -eq 0) { return '' }
    return ([string]::Join($LineEnding, $Lines) + $LineEnding)
}

# The one routine for every write and every restore of pg_hba.conf and pg_ident.conf
# (spec 7.8). The new bytes go to a temp file next to the live file and are swapped in
# with [IO.File]::Replace. Its backup file also sits next to the live file and is never
# $null. File.Replace keeps the live file's DACL but takes owner and group from the temp
# file, so the temp file first gets the live file's owner and group (Set-Acl enables
# the restore privilege for that). Then the live file must exist, hold exactly these
# bytes (SHA-256) and have ExpectedSddl. On any failure the previous bytes go back the
# same way, and the function throws.
function Write-ConfFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][string] $ExpectedSddl
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($full)) {
        throw "Write-ConfFileAtomic: '$full' does not exist. The script only replaces an existing file."
    }
    $dir = [System.IO.Path]::GetDirectoryName($full)
    $leaf = [System.IO.Path]::GetFileName($full)
    $previous = [System.IO.File]::ReadAllBytes($full)
    $sddlBefore = (Get-Acl -LiteralPath $full).Sddl
    $ownerAndGroup = [System.Security.AccessControl.AccessControlSections]'Owner, Group'

    # One swap. Returns { Failure = '' when every check passed, else the reason;
    # Backup = the File.Replace backup path }.
    $swap = {
        param([byte[]] $Data, [string] $WantSddl)
        $tag = '{0}-{1}' -f $PID, [guid]::NewGuid().ToString('N')
        $tmp = Join-Path $dir ('{0}.vbrstd-{1}.tmp' -f $leaf, $tag)
        $bak = Join-Path $dir ('{0}.vbrstd-{1}.old' -f $leaf, $tag)
        $failure = ''
        try {
            [System.IO.File]::WriteAllBytes($tmp, $Data)
            $tmpAcl = Get-Acl -LiteralPath $tmp -ErrorAction Stop
            $tmpAcl.SetSecurityDescriptorSddlForm($sddlBefore, $ownerAndGroup)
            Set-Acl -LiteralPath $tmp -AclObject $tmpAcl -ErrorAction Stop
            [System.IO.File]::Replace($tmp, $full, $bak)
        } catch {
            $failure = "swap failed: $($_.Exception.Message)"
        }
        # File.Replace can fail after it renamed the live file to the backup name
        # (ERROR_UNABLE_TO_MOVE_REPLACEMENT_2). That backup is the live file itself,
        # with its own ACL, so rename it back.
        if (-not [System.IO.File]::Exists($full) -and [System.IO.File]::Exists($bak)) {
            try {
                [System.IO.File]::Move($bak, $full)
            } catch {
                $failure = "$failure; could not rename '$bak' back: $($_.Exception.Message)"
            }
        }
        if (-not $failure) {
            if (-not [System.IO.File]::Exists($full)) {
                $failure = 'the file is missing after the swap'
            } elseif ((Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($full))) -cne (Get-Sha256Hex -Bytes $Data)) {
                $failure = 'the SHA-256 of the file does not match the bytes written'
            } else {
                $sddlNow = (Get-Acl -LiteralPath $full).Sddl
                if ($sddlNow -cne $WantSddl) { $failure = "the SDDL is '$sddlNow', expected '$WantSddl'" }
            }
        }
        try { [System.IO.File]::Delete($tmp) } catch { $failure = "$failure; could not delete '$tmp'" }
        return [pscustomobject]@{ Failure = $failure; Backup = $bak }
    }

    $first = & $swap $Bytes $ExpectedSddl
    if (-not $first.Failure) {
        try {
            [System.IO.File]::Delete($first.Backup)
        } catch {
            Write-Log -Message "Could not delete the swap backup '$($first.Backup)': $($_.Exception.Message)" -Level 'WARN'
        }
        Write-Log -Message "Wrote '$full' ($($Bytes.Length) bytes, sha256 $(Get-Sha256Hex -Bytes $Bytes))."
        return
    }

    # The write failed. Is the live file still the previous file?
    $unchanged = ([System.IO.File]::Exists($full) -and
        (Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($full))) -ceq (Get-Sha256Hex -Bytes $previous) -and
        (Get-Acl -LiteralPath $full).Sddl -ceq $sddlBefore)
    if ($unchanged) {
        try { [System.IO.File]::Delete($first.Backup) } catch { $null = $_ }
        throw "Write-ConfFileAtomic: writing '$full' failed ($($first.Failure)). The file still holds its previous bytes."
    }
    $second = & $swap $previous $sddlBefore
    if (-not $second.Failure) {
        try { [System.IO.File]::Delete($second.Backup) } catch { $null = $_ }
        try { [System.IO.File]::Delete($first.Backup) } catch { $null = $_ }
        throw "Write-ConfFileAtomic: writing '$full' failed ($($first.Failure)). The previous bytes were put back."
    }
    $kept = ''
    if ([System.IO.File]::Exists($first.Backup)) { $kept = " The previous file is kept as '$($first.Backup)'." }
    throw "Write-ConfFileAtomic: writing '$full' failed ($($first.Failure)), and putting the previous bytes back also failed ($($second.Failure)).$kept"
}

# Copies the exact original bytes to <RunDir>\<filename>.before. A backup is never
# overwritten.
function Backup-ConfFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $RunDir
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    $dest = Join-Path ([System.IO.Path]::GetFullPath($RunDir)) ([System.IO.Path]::GetFileName($full) + '.before')
    if ([System.IO.File]::Exists($dest)) {
        throw "Backup-ConfFile: '$dest' already exists. A backup is never overwritten."
    }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    [System.IO.File]::WriteAllBytes($dest, $bytes)
    $hash = Get-Sha256Hex -Bytes $bytes
    if ((Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($dest))) -cne $hash) {
        throw "Backup-ConfFile: '$dest' does not hold the same bytes as '$full'."
    }
    Write-Log -Message "Backed up '$full' to '$dest' (sha256 $hash)."
    return $dest
}

# Puts a run-folder backup back through Write-ConfFileAtomic. A run-folder file is never
# moved or copied into the data folder: it would keep the run folder's ACL (SYSTEM and
# Administrators only), and the PostgreSQL service could no longer read it.
function Restore-ConfFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $BackupPath,
        [Parameter(Mandatory = $true)][string] $ExpectedSddl
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    $bytes = [System.IO.File]::ReadAllBytes($BackupPath)
    if ([System.IO.File]::Exists($full) -and
        (Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($full))) -ceq (Get-Sha256Hex -Bytes $bytes) -and
        (Get-Acl -LiteralPath $full).Sddl -ceq $ExpectedSddl) {
        Write-Log -Message "'$full' already holds the backup bytes. Nothing to restore."
        return
    }
    Write-ConfFileAtomic -Path $full -Bytes $bytes -ExpectedSddl $ExpectedSddl
    Write-Log -Message "Restored '$full' from '$BackupPath'." -Level 'OK'
}
#endregion ConfFiles

#region PgHba
# Splits one pg_hba.conf or pg_ident.conf line into tokens. Space, tab, CR and LF
# separate tokens (PostgreSQL's blanks; a Latin-1 0xA0 is not one). Double quotes keep
# a token whole and are removed. '#' outside quotes starts a comment. Blanks after an
# unquoted comma do not end the token, so 'a, b' is the one list 'a,b', as in
# PostgreSQL. Callers wrap the result in @().
function Split-ConfTokens {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Line)
    $tokens = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    $inQuote = $false
    $hasToken = $false
    $afterComma = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($inQuote) {
            if ($ch -eq [char]34) { $inQuote = $false } else { [void]$current.Append($ch) }
            continue
        }
        if ($ch -eq [char]34) {
            $inQuote = $true
            $hasToken = $true
            $afterComma = $false
            continue
        }
        if ($ch -eq [char]35) { break }
        if ($ch -eq [char]32 -or $ch -eq [char]9 -or $ch -eq [char]13 -or $ch -eq [char]10) {
            if ($afterComma) { continue }
            if ($hasToken) {
                $tokens.Add($current.ToString())
                [void]$current.Clear()
                $hasToken = $false
            }
            continue
        }
        [void]$current.Append($ch)
        $hasToken = $true
        $afterComma = ($ch -eq [char]44)
    }
    if ($hasToken) { $tokens.Add($current.ToString()) }
    return $tokens.ToArray()
}

# Joins continued lines the way PostgreSQL 16 does: an active line whose last character
# is a backslash loses it, and the next physical line is appended directly (a backslash
# followed by a blank is an ordinary character). One object per logical line:
# { LineIndex; Text }, LineIndex being its first physical line. A blank or comment line
# is never joined, so the line after a comment that ends in a backslash (a Windows
# path, say) still counts as active, which is the safe side for Get-HbaFirstMatch and
# Test-PgHbaStandard. A backslash on the last line is dropped. Callers wrap the result
# in @().
function Get-ConfLogicalLines {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines)
    $result = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $Lines.Length) {
        $start = $i
        $text = [string]$Lines[$i]
        $i++
        $trimmed = $text.TrimStart([char[]]@([char]32, [char]9))
        if ($trimmed.Length -gt 0 -and $trimmed[0] -ne [char]35) {
            while ($text.Length -gt 0 -and $text[$text.Length - 1] -eq [char]92) {
                $text = $text.Substring(0, $text.Length - 1)
                if ($i -ge $Lines.Length) { break }
                $text = $text + [string]$Lines[$i]
                $i++
            }
        }
        [void]$result.Add([pscustomobject]@{ LineIndex = $start; Text = $text })
    }
    return $result.ToArray()
}

# One object per active pg_hba.conf line: { LineIndex; Type; Database; User; Address;
# Method; Options }. local lines have Address ''. An IP address followed by a netmask
# column becomes address/prefix. Options is the rest of the line joined by one space.
# A line of any other type (include, include_dir, ...) is still returned, with its
# arguments in Database, so no active line is ever invisible to Test-PgHbaStandard.
# A line continued with a trailing backslash is one rule; its LineIndex is the first
# physical line.
function Get-PgHbaRules {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines)
    $isIpLiteral = {
        param([string] $Text)
        $ip = $null
        return ((($Text -match '^\d{1,3}(\.\d{1,3}){3}$') -or $Text.Contains(':')) -and
            [System.Net.IPAddress]::TryParse($Text, [ref]$ip))
    }
    $logical = @(Get-ConfLogicalLines -Lines $Lines)
    $rules = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $logical.Count; $i++) {
        $t = @(Split-ConfTokens -Line $logical[$i].Text)
        if ($t.Count -eq 0) { continue }
        $type = $t[0]
        $database = ''
        $user = ''
        $address = ''
        $method = ''
        $options = ''
        if ($type -eq 'local' -or $type -like 'host*') {
            if ($t.Count -gt 1) { $database = $t[1] }
            if ($t.Count -gt 2) { $user = $t[2] }
            $next = 3
            if ($type -like 'host*') {
                $next = 4
                if ($t.Count -gt 3) {
                    $address = $t[3]
                    if ($t.Count -gt 4 -and -not $address.Contains('/') -and (& $isIpLiteral $address) -and (& $isIpLiteral $t[4])) {
                        $bits = 0
                        $contiguous = $true
                        $seenZero = $false
                        foreach ($b in ([System.Net.IPAddress]::Parse($t[4])).GetAddressBytes()) {
                            for ($k = 7; $k -ge 0; $k--) {
                                if ((($b -shr $k) -band 1) -eq 1) {
                                    if ($seenZero) { $contiguous = $false }
                                    $bits++
                                } else {
                                    $seenZero = $true
                                }
                            }
                        }
                        if ($contiguous) { $address = "$address/$bits" } else { $address = "$address/$($t[4])" }
                        $next = 5
                    }
                }
            }
            if ($t.Count -gt $next) { $method = $t[$next] }
            if ($t.Count -gt $next + 1) { $options = ($t[($next + 1)..($t.Count - 1)]) -join ' ' }
        } elseif ($t.Count -gt 1) {
            $database = ($t[1..($t.Count - 1)]) -join ' '
        }
        [void]$rules.Add([pscustomobject]@{
            LineIndex = $logical[$i].LineIndex
            Type      = $type
            Database  = $database
            User      = $user
            Address   = $address
            Method    = $method
            Options   = $options
        })
    }
    return $rules.ToArray()
}

# True when an active line includes other files: include, include_if_exists,
# include_dir, or any token (or comma-list item) that starts with @. The script cannot
# see or safely edit included rules (spec 7.1 step 13).
function Test-PgHbaHasInclude {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines)
    foreach ($entry in @(Get-ConfLogicalLines -Lines $Lines)) {
        $t = @(Split-ConfTokens -Line $entry.Text)
        if ($t.Count -eq 0) { continue }
        if (@('include', 'include_if_exists', 'include_dir') -contains $t[0]) { return $true }
        foreach ($token in $t) {
            foreach ($item in $token.Split(',')) {
                if ($item.Length -gt 0 -and $item[0] -eq [char]64) { return $true }
            }
        }
    }
    return $false
}

# Veeam's default SSPI layout (KB4818), spec 7.3.
function Get-StandardPgHbaLines {
    return @(
        'local   all             all                                     sspi map=veeam',
        'host    all             all             127.0.0.1/32            sspi map=veeam',
        'host    all             all             ::1/128                 sspi map=veeam',
        'local   replication     all                                     sspi map=veeam',
        'host    replication     all             127.0.0.1/32            sspi map=veeam',
        'host    replication     all             ::1/128                 sspi map=veeam'
    )
}

# True when the rules are exactly the six standard rules, in order. Type, Database,
# User, Address and Method compare case-insensitively. Options compare as a set of
# words, case-sensitively, because PostgreSQL map names are case-sensitive.
function Test-PgHbaStandard {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Rules)
    $standard = @(Get-PgHbaRules -Lines @(Get-StandardPgHbaLines))
    if ($Rules.Count -ne $standard.Count) { return $false }
    for ($i = 0; $i -lt $standard.Count; $i++) {
        foreach ($field in @('Type', 'Database', 'User', 'Address', 'Method')) {
            $have = [string](Get-CfgValue -Object $Rules[$i] -Name $field -Default '')
            if ($have -ne [string]$standard[$i].$field) { return $false }
        }
        $haveSet = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)
        $wantSet = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)
        foreach ($word in ([string](Get-CfgValue -Object $Rules[$i] -Name 'Options' -Default '')).Split([char[]]@([char]32, [char]9))) {
            if ($word.Length -gt 0) { [void]$haveSet.Add($word) }
        }
        foreach ($word in ([string]$standard[$i].Options).Split([char[]]@([char]32, [char]9))) {
            if ($word.Length -gt 0) { [void]$wantSet.Add($word) }
        }
        if (-not $haveSet.SetEquals($wantSet)) { return $false }
    }
    return $true
}

# Rules of type host* whose Address is not 127.0.0.1/32 or ::1/128 (LAN lines,
# samehost, samenet, host names). Spec 7.5 lists them in Detail when they are
# commented out.
function Get-NonLoopbackHbaRules {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Rules)
    $result = New-Object System.Collections.ArrayList
    foreach ($rule in $Rules) {
        if ([string](Get-CfgValue -Object $rule -Name 'Type' -Default '') -notlike 'host*') { continue }
        $address = [string](Get-CfgValue -Object $rule -Name 'Address' -Default '')
        $isLoopback = $false
        if ($address -match '^([^/]+)/(\d+)$') {
            $prefix = $Matches[2]
            $ip = $null
            if ([System.Net.IPAddress]::TryParse($Matches[1], [ref]$ip)) {
                $text = $ip.ToString()
                if (($text -eq '127.0.0.1' -and $prefix -eq '32') -or ($text -eq '::1' -and $prefix -eq '128')) {
                    $isLoopback = $true
                }
            }
        }
        if (-not $isLoopback) { [void]$result.Add($rule) }
    }
    return $result.ToArray()
}

# The first rule that a TCP connection (database, user, client IP) would use, or $null.
# local lines never match. Database: all, sameuser (only when Database equals User),
# or an exact case-sensitive name; replication never matches a normal connection. User:
# all or an exact name. Comma lists match when any item matches. What the script cannot
# decide offline counts as a match: samerole, +group, @file, /regex, host names,
# samehost, samenet, hostssl and hostnossl. So the answer can be "the first rule may be
# another one", but never a false "the first rule is sspi".
function Get-HbaFirstMatch {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Rules,
        [Parameter(Mandatory = $true)][string] $Database,
        [Parameter(Mandatory = $true)][string] $User,
        [Parameter(Mandatory = $true)][string] $Address
    )
    $client = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$client)) {
        throw "Get-HbaFirstMatch: '$Address' is not an IP address."
    }
    $clientBytes = $client.GetAddressBytes()
    foreach ($rule in $Rules) {
        if ([string](Get-CfgValue -Object $rule -Name 'Type' -Default '') -notlike 'host*') { continue }

        $databaseOk = $false
        foreach ($item in ([string](Get-CfgValue -Object $rule -Name 'Database' -Default '')).Split(',')) {
            if ($item -eq 'all') { $databaseOk = $true }
            elseif ($item -eq 'sameuser') { if ($Database -ceq $User) { $databaseOk = $true } }
            elseif ($item -ceq 'replication') { }
            elseif ($item -eq 'samerole' -or $item -eq 'samegroup') { $databaseOk = $true }
            elseif ($item.Length -gt 0 -and ($item[0] -eq [char]64 -or $item[0] -eq [char]47)) { $databaseOk = $true }
            elseif ($item -ceq $Database) { $databaseOk = $true }
        }
        if (-not $databaseOk) { continue }

        $userOk = $false
        foreach ($item in ([string](Get-CfgValue -Object $rule -Name 'User' -Default '')).Split(',')) {
            if ($item -eq 'all') { $userOk = $true }
            elseif ($item.Length -gt 0 -and ($item[0] -eq [char]43 -or $item[0] -eq [char]64 -or $item[0] -eq [char]47)) { $userOk = $true }
            elseif ($item -ceq $User) { $userOk = $true }
        }
        if (-not $userOk) { continue }

        $addressOk = $true
        $ruleAddress = [string](Get-CfgValue -Object $rule -Name 'Address' -Default '')
        if ($ruleAddress -match '^([^/]+)/(\d{1,3})$') {
            $prefix = [int]$Matches[2]
            $network = $null
            if ([System.Net.IPAddress]::TryParse($Matches[1], [ref]$network)) {
                $networkBytes = $network.GetAddressBytes()
                if ($networkBytes.Length -ne $clientBytes.Length) {
                    $addressOk = $false
                } elseif ($prefix -le $networkBytes.Length * 8) {
                    $wholeBytes = [int][System.Math]::Floor($prefix / 8)
                    $restBits = $prefix % 8
                    for ($k = 0; $k -lt $wholeBytes; $k++) {
                        if ($clientBytes[$k] -ne $networkBytes[$k]) { $addressOk = $false; break }
                    }
                    if ($addressOk -and $restBits -gt 0) {
                        $mask = (0xFF -shl (8 - $restBits)) -band 0xFF
                        if (([int]$clientBytes[$wholeBytes] -band $mask) -ne ([int]$networkBytes[$wholeBytes] -band $mask)) {
                            $addressOk = $false
                        }
                    }
                }
            }
        }
        if ($addressOk) { return $rule }
    }
    return $null
}

# The new pg_hba.conf text (spec 7.8): a header comment, the six standard lines, then
# every original line. Original active lines are commented out with the ASCII prefix
# '# [VbrStandardise <Stamp>] ' in front of their original characters; comment and blank
# lines stay as they are.
function New-PgHbaText {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines,
        [Parameter(Mandatory = $true)][string] $LineEnding,
        [Parameter(Mandatory = $true)][string] $Stamp
    )
    if (-not (Test-AsciiText -Text $Stamp)) { throw "New-PgHbaText: the stamp '$Stamp' is not printable ASCII." }
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("# Standardised by Invoke-VbrStandardise.ps1 on $Stamp")
    foreach ($line in @(Get-StandardPgHbaLines)) { $out.Add($line) }
    $prefix = "# [VbrStandardise $Stamp] "
    foreach ($line in $Lines) {
        if (@(Split-ConfTokens -Line $line).Count -gt 0) { $out.Add($prefix + $line) } else { $out.Add($line) }
    }
    return (Join-ConfLines -Lines $out.ToArray() -LineEnding $LineEnding)
}
#endregion PgHba

#region PgIdent
# One object per active pg_ident.conf line: { LineIndex; Map; SystemUser; PgUser },
# quotes removed. A short line gets '' for the missing fields.
function Get-PgIdentEntries {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines)
    $entries = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Lines.Length; $i++) {
        $t = @(Split-ConfTokens -Line $Lines[$i])
        if ($t.Count -eq 0) { continue }
        $systemUser = ''
        $pgUser = ''
        if ($t.Count -gt 1) { $systemUser = $t[1] }
        if ($t.Count -gt 2) { $pgUser = $t[2] }
        [void]$entries.Add([pscustomobject]@{
            LineIndex  = $i
            Map        = $t[0]
            SystemUser = $systemUser
            PgUser     = $pgUser
        })
    }
    return $entries.ToArray()
}

# A set of names that compares case-insensitively, as PostgreSQL compares SSPI names.
# Empty and $null names are skipped. Every name lookup in this region goes through this
# one set, so the de-duplication, the check and the render cannot disagree on case. The
# set is returned with the unary comma so that PowerShell does not unroll it into a list.
function New-IdentNameSet {
    param([AllowNull()][AllowEmptyCollection()][string[]] $Names = @())
    $set = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($Names)) {
        if (-not [string]::IsNullOrEmpty($name)) { [void]$set.Add($name) }
    }
    return ,$set
}

# The names the veeam map must hold (spec 7.3): SYSTEM, then svc_veeam, then the
# accounts of Veeam services that do not run as LocalSystem. Duplicates are removed
# case-insensitively (PostgreSQL compares SSPI names case-insensitively); the first
# spelling wins. Empty names are skipped, so a missing svc_veeam gives no empty line.
function Get-RequiredIdentNames {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $SvcMapName,
        [string[]] $ServiceAccountMapNames = @()
    )
    $seen = New-IdentNameSet
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($name in (@('SYSTEM@NT AUTHORITY', $SvcMapName) + @($ServiceAccountMapNames))) {
        if ([string]::IsNullOrEmpty($name)) { continue }
        if ($seen.Add($name)) { $names.Add($name) }
    }
    return $names.ToArray()
}

# The one place that decides how a pg_ident.conf maps against the required names. Both
# Get-PgIdentStatus (the check) and New-PgIdentText (the render) read its result, so the
# text the renderer writes is always the text the checker calls STANDARD.
# Only the map named exactly 'veeam' is managed; the map name and the role are
# case-sensitive, as in PostgreSQL ('Veeam' is another map, 'Postgres' another role).
# System names compare case-insensitively. A veeam entry is kept when it maps a required
# name to postgres; any other veeam entry is extra (this includes a regex system user,
# which is never a required literal, and a short line). A required name that appears
# twice is not extra. Returns { ExtraLineIndexes: int[]; MissingNames: string[] }:
# the LineIndex of every extra entry (-1 for an entry that has none), and every required
# name with no kept entry, once each, in RequiredNames order.
function Get-PgIdentFindings {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Entries,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $RequiredNames
    )
    $required = New-IdentNameSet -Names $RequiredNames
    $mapped = New-IdentNameSet
    $extraLineIndexes = New-Object System.Collections.Generic.List[int]
    foreach ($entry in $Entries) {
        if ([string](Get-CfgValue -Object $entry -Name 'Map' -Default '') -cne 'veeam') { continue }
        $systemUser = [string](Get-CfgValue -Object $entry -Name 'SystemUser' -Default '')
        $pgUser = [string](Get-CfgValue -Object $entry -Name 'PgUser' -Default '')
        if ($pgUser -ceq 'postgres' -and $required.Contains($systemUser)) {
            [void]$mapped.Add($systemUser)
        } else {
            $extraLineIndexes.Add([int](Get-CfgValue -Object $entry -Name 'LineIndex' -Default -1))
        }
    }
    $missingNames = New-Object System.Collections.Generic.List[string]
    foreach ($name in $RequiredNames) {
        if ([string]::IsNullOrEmpty($name) -or $mapped.Contains($name)) { continue }
        $missingNames.Add($name)
        [void]$mapped.Add($name)
    }
    return [pscustomobject]@{
        ExtraLineIndexes = $extraLineIndexes.ToArray()
        MissingNames     = $missingNames.ToArray()
    }
}

# STANDARD when the veeam map holds every required name mapped to postgres and nothing
# else. MISSING_ENTRY when a required name has no veeam entry to postgres; EXTRA_ENTRY
# when a veeam entry is not required or maps to another role. MISSING wins over EXTRA.
# The rules are in Get-PgIdentFindings.
function Get-PgIdentStatus {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Entries,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $RequiredNames
    )
    $findings = Get-PgIdentFindings -Entries $Entries -RequiredNames $RequiredNames
    if ($findings.MissingNames.Count -gt 0) { return 'MISSING_ENTRY' }
    if ($findings.ExtraLineIndexes.Count -gt 0) { return 'EXTRA_ENTRY' }
    return 'STANDARD'
}

# The new pg_ident.conf text (spec 7.8). Lines outside the veeam map stay as they are.
# A veeam line that is not required, or maps to another role, gets the ASCII prefix
# '# [VbrStandardise <Stamp>] ' in front of its original characters. Each required name
# without a veeam line to postgres is appended as: veeam   "<name>"   postgres
# Which lines and names those are comes from Get-PgIdentFindings, the same result
# Get-PgIdentStatus reads. New lines are ASCII only: a name that is not printable ASCII,
# or holds a double quote, is refused (throw) rather than written.
function New-PgIdentText {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $RequiredNames,
        [Parameter(Mandatory = $true)][string] $LineEnding,
        [Parameter(Mandatory = $true)][string] $Stamp
    )
    if (-not (Test-AsciiText -Text $Stamp)) { throw "New-PgIdentText: the stamp '$Stamp' is not printable ASCII." }
    $findings = Get-PgIdentFindings -Entries @(Get-PgIdentEntries -Lines $Lines) -RequiredNames $RequiredNames
    $extra = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($index in $findings.ExtraLineIndexes) { [void]$extra.Add($index) }
    $prefix = "# [VbrStandardise $Stamp] "
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Lines.Length; $i++) {
        if ($extra.Contains($i)) { $out.Add($prefix + $Lines[$i]) } else { $out.Add($Lines[$i]) }
    }
    foreach ($name in $findings.MissingNames) {
        if (-not (Test-AsciiText -Text $name) -or $name.Contains('"')) {
            throw "New-PgIdentText: the name '$name' is not printable ASCII or holds a double quote. It is not written to pg_ident.conf."
        }
        $out.Add('veeam   "' + $name + '"   postgres')
    }
    return (Join-ConfLines -Lines $out.ToArray() -LineEnding $LineEnding)
}
#endregion PgIdent

#region Psql
# Runs one SQL text through psql as the current Windows account (SSPI) and the
# postgres role. libpq reads PGUSER, PGHOST, PGPASSWORD, PGSERVICE, PGSSLMODE and a
# pgpass file; any of them could make a login work for a reason other than SSPI, so
# they are cleared for the call, PGPASSFILE points at nul, and every old value is put
# back in finally. -X skips psqlrc (it could add text to stdout) and -w never
# prompts. With -ViaStdin the SQL goes to psql's stdin (-f -), not its command line.
function Invoke-PgQuery {
    param(
        [Parameter(Mandatory)][string] $Psql,
        [Parameter(Mandatory)][int]    $Port,
        [Parameter(Mandatory)][string] $HostAddress,
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][string] $Sql,
        [switch] $ViaStdin
    )
    $clearNames = @('PGUSER', 'PGHOST', 'PGPASSWORD', 'PGSERVICE', 'PGSSLMODE')
    $setValues  = [ordered]@{ PGPASSFILE = 'nul'; PGCONNECT_TIMEOUT = '10' }
    $allNames   = @($clearNames) + @($setValues.Keys)
    $saved = @{}
    foreach ($name in $allNames) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $psqlArgs = @('-X', '-w', '-h', $HostAddress, '-p', "$Port", '-U', 'postgres', '-d', $Database, '-t', '-A')
    $result = $null
    try {
        foreach ($name in $clearNames) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
        foreach ($name in @($setValues.Keys)) { [Environment]::SetEnvironmentVariable($name, $setValues[$name], 'Process') }
        if ($ViaStdin) {
            $result = Invoke-Native -FilePath $Psql -Arguments ($psqlArgs + @('-f', '-')) -StdinText $Sql
        } else {
            $result = Invoke-Native -FilePath $Psql -Arguments ($psqlArgs + @('-c', $Sql))
        }
    } finally {
        foreach ($name in $allNames) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        StdOut   = "$($result.StdOut)"
        StdErr   = "$($result.StdErr)"
    }
}

# Sorts a psql stderr text into AUTH (the server refused the login), CONNECT (no
# server answered) or OTHER. AUTH is tested first: a refused login also says
# "connection to server ... failed". The SQLSTATE codes catch a server whose
# lc_messages is not English.
function Get-PsqlFailureKind {
    param([string] $StdErr)
    $text = "$StdErr"
    if ($text -match 'SSPI authentication failed|no pg_hba\.conf entry|no match in usermap|password authentication failed|no password supplied|\b28000:|\b28P01:') {
        return 'AUTH'
    }
    if ($text -match 'Connection refused|could not connect|timeout expired|\b10061\b') {
        return 'CONNECT'
    }
    return 'OTHER'
}

# Spec 7.9: SELECT 1 as postgres on every listening loopback address. Passed only
# when every address answers 1. An empty address list is never a pass.
function Test-PgSspiLogin {
    param(
        [Parameter(Mandatory)][string] $Psql,
        [Parameter(Mandatory)][int]    $Port,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Addresses,
        [Parameter(Mandatory)][string] $Database
    )
    $results = New-Object System.Collections.ArrayList
    $passed = $true
    foreach ($address in @($Addresses)) {
        $res = Invoke-PgQuery -Psql $Psql -Port $Port -HostAddress $address -Database $Database -Sql 'SELECT 1;'
        $out = "$($res.StdOut)".Trim()
        if ($res.ExitCode -eq 0 -and $out -ceq '1') {
            $kind = 'OK'
        } elseif ($res.ExitCode -eq 0) {
            $kind = 'OTHER'
        } else {
            $kind = Get-PsqlFailureKind -StdErr $res.StdErr
        }
        if ($kind -ne 'OK') { $passed = $false }
        [void]$results.Add([pscustomobject]@{
            Address  = $address
            ExitCode = $res.ExitCode
            Kind     = $kind
            StdErr   = "$($res.StdErr)"
        })
        if ($kind -eq 'OK') {
            Write-Log -Message "SSPI login as postgres to '$Database' on ${address}: OK" -Level OK
        } else {
            Write-Log -Message (Format-ShortText -Text "SSPI login as postgres to '$Database' on ${address}: $kind (exit $($res.ExitCode)) $($res.StdErr)" -MaxLength 400) -Level WARN
        }
    }
    if ($results.Count -eq 0) {
        $passed = $false
        Write-Log -Message 'SSPI login test had no listening address to test' -Level WARN
    }
    return [pscustomobject]@{ Passed = $passed; Results = $results.ToArray() }
}

# SHOW hba_file returns a forward-slash path on Windows. Turn both sides into one
# comparable form: backslashes, full path, no trailing backslash, lower case.
function ConvertTo-ComparablePath {
    param([string] $Path)
    $text = "$Path".Trim().Trim('"').Trim()
    if ($text -eq '') { return '' }
    $text = $text.Replace('/', '\')
    try { $text = [IO.Path]::GetFullPath($text) } catch { $text = $text }
    return $text.TrimEnd('\').ToLowerInvariant()
}

function Test-SamePath {
    param([string] $Left, [string] $Right)
    $l = ConvertTo-ComparablePath -Path $Left
    $r = ConvertTo-ComparablePath -Path $Right
    return ($l -ne '' -and $l -ceq $r)
}

# Spec 7.9 second half: the files PostgreSQL loads parse without errors, and the
# live hba_file and ident_file are the files this script edits. The
# pg_ident_file_mappings view exists from PostgreSQL 15 only.
function Test-PgConfigHealth {
    param(
        [Parameter(Mandatory)][string] $Psql,
        [Parameter(Mandatory)][int]    $Port,
        [Parameter(Mandatory)][string] $Address,
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][int]    $Major,
        [Parameter(Mandatory)][string] $HbaPath,
        [Parameter(Mandatory)][string] $IdentPath
    )
    $problems = New-Object System.Collections.ArrayList
    $countChecks = [ordered]@{ 'pg_hba_file_rules' = 'SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;' }
    if ($Major -ge 15) {
        $countChecks['pg_ident_file_mappings'] = 'SELECT count(*) FROM pg_ident_file_mappings WHERE error IS NOT NULL;'
    }
    foreach ($view in @($countChecks.Keys)) {
        $res = Invoke-PgQuery -Psql $Psql -Port $Port -HostAddress $Address -Database $Database -Sql $countChecks[$view]
        $out = "$($res.StdOut)".Trim()
        if ($res.ExitCode -ne 0) {
            [void]$problems.Add((Format-ShortText -Text "$view query failed (exit $($res.ExitCode)): $($res.StdErr)" -MaxLength 300))
        } elseif ($out -cne '0') {
            [void]$problems.Add("$view reports '$out' line(s) with errors")
        }
    }
    $fileChecks = [ordered]@{ 'hba_file' = $HbaPath; 'ident_file' = $IdentPath }
    foreach ($setting in @($fileChecks.Keys)) {
        $res = Invoke-PgQuery -Psql $Psql -Port $Port -HostAddress $Address -Database $Database -Sql "SHOW $setting;"
        $out = "$($res.StdOut)".Trim()
        if ($res.ExitCode -ne 0) {
            [void]$problems.Add((Format-ShortText -Text "SHOW $setting failed (exit $($res.ExitCode)): $($res.StdErr)" -MaxLength 300))
        } elseif (-not (Test-SamePath -Left $out -Right $fileChecks[$setting])) {
            [void]$problems.Add("live $setting is '$out', not '$($fileChecks[$setting])'")
        }
    }
    if ($problems.Count -eq 0) {
        return [pscustomobject]@{ Ok = $true; Detail = 'pg_hba.conf and pg_ident.conf load without errors and are the files this script edits' }
    }
    return [pscustomobject]@{ Ok = $false; Detail = ($problems -join '; ') }
}

# Spec 7.4: what SYSTEM can see over SSPI. PasswordSet comes from
# "rolpassword IS NULL" only; the hash is never read. Backends are the other client
# sessions; start times come back as epoch milliseconds and become UTC DateTimes.
function Get-PgLiveState {
    param(
        [Parameter(Mandatory)][string] $Psql,
        [Parameter(Mandatory)][int]    $Port,
        [Parameter(Mandatory)][string] $Address,
        [Parameter(Mandatory)][string] $Database
    )
    $failed = [pscustomobject]@{ Ok = $false; PasswordSet = $false; Backends = @() }
    $passwordSql = "SELECT CASE WHEN rolpassword IS NULL THEN 'NONE' ELSE 'SET' END FROM pg_authid WHERE rolname = 'postgres';"
    $pw = Invoke-PgQuery -Psql $Psql -Port $Port -HostAddress $Address -Database $Database -Sql $passwordSql
    $pwText = "$($pw.StdOut)".Trim()
    if ($pw.ExitCode -ne 0 -or ($pwText -cne 'NONE' -and $pwText -cne 'SET')) {
        Write-Log -Message (Format-ShortText -Text "Could not read whether the postgres role has a password (exit $($pw.ExitCode)): $($pw.StdErr)" -MaxLength 400) -Level WARN
        return $failed
    }
    $backendSql = "SELECT COALESCE(json_agg(json_build_object('pid', pid, 'usename', usename, 'datname', datname, 'client_addr', host(client_addr), 'start_ms', (extract(epoch FROM backend_start) * 1000)::bigint) ORDER BY pid)::text, '[]') FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid();"
    $be = Invoke-PgQuery -Psql $Psql -Port $Port -HostAddress $Address -Database $Database -Sql $backendSql
    if ($be.ExitCode -ne 0) {
        Write-Log -Message (Format-ShortText -Text "Could not read pg_stat_activity (exit $($be.ExitCode)): $($be.StdErr)" -MaxLength 400) -Level WARN
        return $failed
    }
    try {
        $items = @(ConvertFrom-JsonArrayText -Text "$($be.StdOut)".Trim())
    } catch {
        Write-Log -Message (Format-ShortText -Text "Could not parse pg_stat_activity output: $($_.Exception.Message)" -MaxLength 400) -Level WARN
        return $failed
    }
    $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    $backends = New-Object System.Collections.ArrayList
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $ms = Get-CfgValue -Object $item -Name 'start_ms' -Default $null
        $start = New-Object DateTime 1, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
        if ($null -ne $ms -and "$ms" -ne '') { $start = $epoch.AddMilliseconds([double]$ms) }
        [void]$backends.Add([pscustomobject]@{
            Pid             = [int](Get-CfgValue -Object $item -Name 'pid' -Default 0)
            UseName         = "$(Get-CfgValue -Object $item -Name 'usename' -Default '')"
            DatName         = "$(Get-CfgValue -Object $item -Name 'datname' -Default '')"
            ClientAddr      = "$(Get-CfgValue -Object $item -Name 'client_addr' -Default '')"
            BackendStartUtc = $start
        })
    }
    return [pscustomobject]@{
        Ok          = $true
        PasswordSet = ($pwText -ceq 'SET')
        Backends    = $backends.ToArray()
    }
}

# Spec 7.6 Path B step 13: login roles other than postgres that still have a
# password. rolpassword is only a filter here. On a failed query the list is empty
# and a warning is logged, because this list is information only.
function Get-OtherPasswordRoles {
    param(
        [Parameter(Mandatory)][string] $Psql,
        [Parameter(Mandatory)][int]    $Port,
        [Parameter(Mandatory)][string] $Address,
        [Parameter(Mandatory)][string] $Database
    )
    $sql = "SELECT COALESCE(json_agg(rolname ORDER BY rolname)::text, '[]') FROM pg_authid WHERE rolcanlogin AND rolname <> 'postgres' AND rolpassword IS NOT NULL;"
    $res = Invoke-PgQuery -Psql $Psql -Port $Port -HostAddress $Address -Database $Database -Sql $sql
    if ($res.ExitCode -ne 0) {
        Write-Log -Message (Format-ShortText -Text "Could not list other login roles with a password (exit $($res.ExitCode)): $($res.StdErr)" -MaxLength 400) -Level WARN
        return [string[]]@()
    }
    try {
        $names = @(ConvertFrom-JsonArrayText -Text "$($res.StdOut)".Trim())
    } catch {
        Write-Log -Message (Format-ShortText -Text "Could not parse the list of other login roles with a password: $($_.Exception.Message)" -MaxLength 400) -Level WARN
        return [string[]]@()
    }
    return [string[]]@($names | Where-Object { $null -ne $_ } | ForEach-Object { "$_" })
}

# Spec 7.10: remove the postgres password. The ALTER goes through stdin, then a
# fresh session checks "rolpassword IS NULL". psql -f - can exit 0 after an SQL
# error, so only the re-check proves the result.
function Clear-PostgresPassword {
    param(
        [Parameter(Mandatory)][string] $Psql,
        [Parameter(Mandatory)][int]    $Port,
        [Parameter(Mandatory)][string] $Address,
        [Parameter(Mandatory)][string] $Database
    )
    $alter = Invoke-PgQuery -Psql $Psql -Port $Port -HostAddress $Address -Database $Database -Sql 'ALTER ROLE postgres PASSWORD NULL;' -ViaStdin
    if ($alter.ExitCode -ne 0) {
        $detail = Format-ShortText -Text "ALTER ROLE failed (exit $($alter.ExitCode)): $($alter.StdErr)" -MaxLength 400
        Write-Log -Message $detail -Level WARN
        return [pscustomobject]@{ Ok = $false; Detail = $detail }
    }
    $checkSql = "SELECT CASE WHEN rolpassword IS NULL THEN 'NONE' ELSE 'SET' END FROM pg_authid WHERE rolname = 'postgres';"
    $check = Invoke-PgQuery -Psql $Psql -Port $Port -HostAddress $Address -Database $Database -Sql $checkSql
    $state = "$($check.StdOut)".Trim()
    if ($check.ExitCode -eq 0 -and $state -ceq 'NONE') {
        Write-Log -Message 'The postgres role has no password now' -Level OK
        return [pscustomobject]@{ Ok = $true; Detail = 'The postgres role has no password' }
    }
    $detail = Format-ShortText -Text "The postgres password is still set or could not be checked (check '$state', exit $($check.ExitCode)) $($check.StdErr) $($alter.StdErr)" -MaxLength 400
    Write-Log -Message $detail -Level WARN
    return [pscustomobject]@{ Ok = $false; Detail = $detail }
}
#endregion Psql

#region State
# Spec 7.4, third WINDOWS condition: every session on the VBR database is the
# postgres role from 127.0.0.1 or ::1. No session at all contradicts nothing.
function Test-VbrBackendsOk {
    param(
        [object[]] $Backends,
        [Parameter(Mandatory)][string] $Database
    )
    foreach ($backend in @($Backends)) {
        if ($null -eq $backend) { continue }
        $datName = "$(Get-CfgValue -Object $backend -Name 'DatName' -Default '')"
        if ($datName -ine $Database) { continue }
        $useName = "$(Get-CfgValue -Object $backend -Name 'UseName' -Default '')"
        $address = "$(Get-CfgValue -Object $backend -Name 'ClientAddr' -Default '')".Trim()
        if ($useName -cne 'postgres') { return $false }
        if ($address -ne '127.0.0.1' -and $address -ne '::1') { return $false }
    }
    return $true
}

# Spec 7.4: NATIVE follows the registry alone. WINDOWS needs the registry and all
# three live checks. Anything else is UNKNOWN, and UNKNOWN blocks every change.
function Get-DbAuthState {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $RegistryAuth,
        [Parameter(Mandatory)][bool] $SspiPassed,
        [Parameter(Mandatory)][bool] $FirstMatchOk,
        [Parameter(Mandatory)][bool] $VbrBackendsOk
    )
    if ($RegistryAuth -eq 'NATIVE') { return 'NATIVE' }
    if ($RegistryAuth -eq 'WINDOWS' -and $SspiPassed -and $FirstMatchOk -and $VbrBackendsOk) { return 'WINDOWS' }
    return 'UNKNOWN'
}

# Spec 7.5 without SSPI: remote addresses of established TCP sessions on the
# PostgreSQL port. Loopback (127.0.0.0/8, ::1, ::ffff:127.x) is left out; each
# address is listed once, sorted.
function Select-RemoteClients {
    param(
        [object[]] $Connections,
        [Parameter(Mandatory)][int] $Port
    )
    $found = New-Object System.Collections.ArrayList
    foreach ($connection in @($Connections)) {
        if ($null -eq $connection) { continue }
        if ("$(Get-CfgValue -Object $connection -Name 'State' -Default '')" -ne 'Established') { continue }
        $localPort = "$(Get-CfgValue -Object $connection -Name 'LocalPort' -Default '')" -as [int]
        if ($null -eq $localPort -or $localPort -ne $Port) { continue }
        $remote = "$(Get-CfgValue -Object $connection -Name 'RemoteAddress' -Default '')".Trim()
        if ($remote -eq '' -or $remote -eq '::1' -or $remote -like '127.*' -or $remote -like '::ffff:127.*') { continue }
        if (-not ($found -contains $remote)) { [void]$found.Add($remote) }
    }
    return [string[]]@($found | Sort-Object)
}

# Wrapper over Get-NetTCPConnection. "No MSFT_NetTCPConnection objects found" is
# how the cmdlet says "no session"; any other error is thrown, so a broken check
# never reads as "no remote client".
function Get-EstablishedRemoteClients {
    param([Parameter(Mandatory)][int] $Port)
    $tcpErrors = $null
    $connections = @(Get-NetTCPConnection -State Established -LocalPort $Port -ErrorAction SilentlyContinue -ErrorVariable tcpErrors)
    foreach ($tcpError in @($tcpErrors)) {
        if ($null -eq $tcpError) { continue }
        if ("$($tcpError.CategoryInfo.Category)" -ne 'ObjectNotFound') {
            throw "Get-NetTCPConnection failed for port ${Port}: $($tcpError.Exception.Message)"
        }
    }
    return [string[]]@(Select-RemoteClients -Connections $connections -Port $Port)
}

# Spec 7.5 blockers. Returns at most one PG_PASSWORD_CONSUMER and one
# PG_REMOTE_CONSUMER, each listing every source. Backends is $null when SYSTEM
# cannot log in over SSPI yet; then only the TCP view (RemoteClients) is used.
function Get-ConsumerIssues {
    param(
        [Parameter(Mandatory)][object] $DbConfig,
        [object]   $EmConfig,
        [object[]] $Backends,
        [string[]] $RemoteClients,
        [string[]] $LocalNames
    )
    $hostNames = @(@($LocalNames) + @('localhost') | Where-Object { "$_" -ne '' })
    $ownAddresses = @($hostNames | ForEach-Object { ("$_" -replace '%.*$', '').ToLowerInvariant() })
    $dbHost = "$(Get-CfgValue -Object $DbConfig -Name 'HostName' -Default '')".Trim()
    $dbPort = "$(Get-CfgValue -Object $DbConfig -Name 'Port' -Default '')" -as [int]
    $vbrUsesOwnAddress = ($dbHost -ne '' -and (Get-DbHostClass -HostName $dbHost -LocalNames $hostNames) -eq 'LOCAL')

    # Fail closed: an empty host or port counts as this instance.
    $onThisInstance = {
        param([string] $HostName, $PortValue)
        $name = "$HostName".Trim()
        $hostOk = ($name -eq '') -or ((Get-DbHostClass -HostName $name -LocalNames $hostNames) -ne 'REMOTE')
        $portNumber = "$PortValue" -as [int]
        $portOk = ($null -eq $portNumber) -or ($portNumber -eq 0) -or ($null -eq $dbPort) -or ($portNumber -eq $dbPort)
        return ($hostOk -and $portOk)
    }

    $passwordReasons = New-Object System.Collections.ArrayList
    $remote = New-Object System.Collections.ArrayList
    $addRemote = {
        param([string] $Address)
        $bare = ($Address -replace '%.*$', '').ToLowerInvariant()
        if ($vbrUsesOwnAddress -and ($ownAddresses -contains $bare)) { return }
        if (-not ($remote -contains $Address)) { [void]$remote.Add($Address) }
    }

    if ($null -ne $EmConfig) {
        $emActive = "$(Get-CfgValue -Object $EmConfig -Name 'ActiveConfiguration' -Default '')".Trim()
        $emHost = "$(Get-CfgValue -Object $EmConfig -Name 'HostName' -Default '')".Trim()
        $emPort = Get-CfgValue -Object $EmConfig -Name 'Port' -Default $null
        $emPassword = ((Get-CfgValue -Object $EmConfig -Name 'PasswordSet' -Default $false) -eq $true)
        if ($emPassword -and ($emActive -eq '' -or $emActive -ieq 'PostgreSql') -and (& $onThisInstance $emHost $emPort)) {
            [void]$passwordReasons.Add("Enterprise Manager uses a password for its database on this instance (host '$emHost', port '$emPort')")
        }
    }

    if ((Get-CfgValue -Object $DbConfig -Name 'EntraIdPasswordSet' -Default $false) -eq $true) {
        $entraHost = "$(Get-CfgValue -Object $DbConfig -Name 'EntraIdHost' -Default '')".Trim()
        $entraPort = Get-CfgValue -Object $DbConfig -Name 'EntraIdPort' -Default $null
        if (& $onThisInstance $entraHost $entraPort) {
            [void]$passwordReasons.Add("Entra ID repository uses a password for its database on this instance (host '$entraHost', port '$entraPort')")
        }
    }

    if ($null -ne $Backends) {
        $otherRoles = New-Object System.Collections.ArrayList
        foreach ($backend in @($Backends)) {
            if ($null -eq $backend) { continue }
            $useName = "$(Get-CfgValue -Object $backend -Name 'UseName' -Default '')"
            $address = "$(Get-CfgValue -Object $backend -Name 'ClientAddr' -Default '')".Trim()
            if ($useName -cne 'postgres') {
                $label = $useName
                if ($label -eq '') { $label = '(unknown role)' }
                if (-not $otherRoles.Contains($label)) { [void]$otherRoles.Add($label) }
            }
            if ($address -ne '' -and $address -ne '127.0.0.1' -and $address -ne '::1') { & $addRemote $address }
        }
        if ($otherRoles.Count -gt 0) {
            [void]$passwordReasons.Add("sessions as role(s) other than postgres: $($otherRoles -join ', ')")
        }
    }

    foreach ($client in @($RemoteClients)) {
        $text = "$client".Trim()
        if ($text -ne '') { & $addRemote $text }
    }

    $issues = New-Object System.Collections.ArrayList
    if ($passwordReasons.Count -gt 0) {
        [void]$issues.Add([pscustomobject]@{
            Code   = 'PG_PASSWORD_CONSUMER'
            Detail = "PostgreSQL password clients: $($passwordReasons -join '; ')"
            Action = 'Move the listed PostgreSQL password clients to Windows authentication or stop them, then re-run'
        })
    }
    if ($remote.Count -gt 0) {
        [void]$issues.Add([pscustomobject]@{
            Code   = 'PG_REMOTE_CONSUMER'
            Detail = "Clients connected to PostgreSQL from other addresses: $((@($remote) | Sort-Object) -join ', ')"
            Action = 'Move or stop the remote client, then re-run'
        })
    }
    return $issues.ToArray()
}
#endregion State

#region Services
# Idle gate (spec 7.11). Busy means a running job process (Veeam.Backup.Manager),
# a data mover (VeeamAgent) or an Explorer, which can be running an item-level
# restore. The console (Veeam.Backup.Shell) is a client and is not busy. Persistent
# means the OLDEST busy process has run longer than PersistentHours, which is what a
# SQL/Oracle log backup or a CDP policy looks like: waiting will never help there.
# A process whose start time cannot be read is busy but never counts as persistent.
function Get-BusyVeeamWork {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]] $Processes,
        [Parameter(Mandatory)][datetime] $Now,
        [Parameter(Mandatory)][ValidateRange(0, 8760)][int] $PersistentHours
    )
    $busyNames = New-Object System.Collections.ArrayList
    $busy = $false
    $oldest = $null
    foreach ($proc in @($Processes | Where-Object { $null -ne $_ })) {
        $nameProp = $proc.PSObject.Properties['Name']
        if ($null -eq $nameProp) { continue }
        $name = "$($nameProp.Value)" -replace '(?i)\.exe$', ''
        $isBusy = ($name -ieq 'Veeam.Backup.Manager') -or ($name -ieq 'VeeamAgent') -or ($name -ilike 'Veeam*Explorer*')
        if (-not $isBusy) { continue }
        $busy = $true
        if (-not ($busyNames -icontains $name)) { [void]$busyNames.Add($name) }
        $start = $null
        try {
            # Reading StartTime of a protected process throws; that only loses the age.
            $startProp = $proc.PSObject.Properties['StartTime']
            if ($null -ne $startProp -and $null -ne $startProp.Value) { $start = [datetime]$startProp.Value }
        } catch { $start = $null }
        if ($null -ne $start -and ($null -eq $oldest -or $start -lt $oldest)) { $oldest = $start }
    }
    $persistent = $false
    if ($busy -and $null -ne $oldest) { $persistent = (($Now - $oldest).TotalHours -gt $PersistentHours) }
    $sortedNames = [string[]]@($busyNames)
    [Array]::Sort($sortedNames, [System.StringComparer]::OrdinalIgnoreCase)
    return [pscustomobject]@{
        Busy       = $busy
        Persistent = $persistent
        Names      = $sortedNames
    }
}

# Every service whose Name starts with Veeam, as plain data (spec 7.6 Path B step 3).
# StartType is recorded for the report and the run folder only: this script never
# changes a startup type (spec 7.12). Dependents comes from DependentServices, which
# Windows fills with direct and indirect dependents. A failed enumeration throws
# (no match is not an error for a wildcard): an empty snapshot must mean "no Veeam
# service", never "could not look", or Path B would switch with services running.
function Get-VeeamServiceSnapshot {
    $result = @()
    foreach ($svc in @(Get-Service -Name 'Veeam*' -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        $name = "$($svc.Name)"
        if ($name -notlike 'Veeam*') { continue }
        $startType = 'Unknown'
        try {
            $startTypeProp = $svc.PSObject.Properties['StartType']
            if ($null -ne $startTypeProp -and "$($startTypeProp.Value)") { $startType = "$($startTypeProp.Value)" }
        } catch { $startType = 'Unknown' }
        $dependsOn = @()
        try { $dependsOn = @($svc.ServicesDependedOn | ForEach-Object { "$($_.Name)" } | Where-Object { $_ }) } catch { $dependsOn = @() }
        $dependents = @()
        try { $dependents = @($svc.DependentServices | ForEach-Object { "$($_.Name)" } | Where-Object { $_ }) } catch { $dependents = @() }
        $result += [pscustomobject]@{
            Name       = $name
            Status     = "$($svc.Status)"
            StartType  = $startType
            DependsOn  = [string[]]$dependsOn
            Dependents = [string[]]$dependents
        }
    }
    return $result
}

# The stop set and the updater's stop order: alphabetical (ordinal, so 5.1 and 7
# agree), with any *Management*Agent* service last. "Running" means any state other
# than Stopped: a service that is starting, paused or already stopping can still
# hold a database connection, so it must be down before the switch.
function Get-StopSet {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]] $Snapshot)
    $plain = New-Object System.Collections.ArrayList
    $agents = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($svc in @($Snapshot | Where-Object { $null -ne $_ })) {
        $name = "$($svc.Name)"
        if (-not $name -or $seen.ContainsKey($name)) { continue }
        if ("$($svc.Status)" -eq 'Stopped') { continue }
        $seen[$name] = $true
        if ($name -like '*Management*Agent*') { [void]$agents.Add($name) } else { [void]$plain.Add($name) }
    }
    $first = [string[]]@($plain)
    $last = [string[]]@($agents)
    [Array]::Sort($first, [System.StringComparer]::OrdinalIgnoreCase)
    [Array]::Sort($last, [System.StringComparer]::OrdinalIgnoreCase)
    return [string[]]@($first + $last)
}

# Running services outside the stop set that depend directly on a member of it
# (spec 7.6 Path B step 3, SERVICE_DEPENDENT_OUTSIDE_SET). Objects carry Name, Status
# and DependsOn; a raw Get-Service object (ServicesDependedOn) is accepted too.
function Get-ExternalDependents {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]] $StopSet,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]] $AllServices
    )
    $inSet = @{}
    foreach ($n in @($StopSet | Where-Object { $_ })) { $inSet["$n"] = $true }
    $found = @{}
    if ($inSet.Count -gt 0) {
        foreach ($svc in @($AllServices | Where-Object { $null -ne $_ })) {
            $name = "$($svc.Name)"
            if (-not $name -or $inSet.ContainsKey($name)) { continue }
            if ("$($svc.Status)" -eq 'Stopped') { continue }
            $deps = @()
            $dependsOnProp = $svc.PSObject.Properties['DependsOn']
            if ($null -ne $dependsOnProp) {
                $deps = @($dependsOnProp.Value | Where-Object { $_ } | ForEach-Object { "$_" })
            } else {
                try { $deps = @($svc.ServicesDependedOn | Where-Object { $_ } | ForEach-Object { "$($_.Name)" }) } catch { $deps = @() }
            }
            foreach ($dep in $deps) {
                if ($dep -and $inSet.ContainsKey($dep)) { $found[$name] = $true; break }
            }
        }
    }
    $result = [string[]]@($found.Keys)
    [Array]::Sort($result, [System.StringComparer]::OrdinalIgnoreCase)
    return $result
}

# Adapted from the updater's Get-VeeamServiceStartOrder: a topological sort over
# DependsOn, in waves. Only dependencies that are themselves in Names are waited for
# (Windows starts RpcSs and friends on its own). Each wave is sorted alphabetically.
# Anything left in a cycle is appended alphabetically, never dropped. A name with no
# snapshot entry has no known dependencies.
function Get-StartOrder {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]] $Snapshot,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]] $Names
    )
    $wanted = New-Object System.Collections.ArrayList
    $inSet = @{}
    foreach ($n in @($Names | Where-Object { $_ })) {
        if ($inSet.ContainsKey("$n")) { continue }
        $inSet["$n"] = $true
        [void]$wanted.Add("$n")
    }
    $deps = @{}
    foreach ($rec in @($Snapshot | Where-Object { $null -ne $_ })) {
        $nameProp = $rec.PSObject.Properties['Name']
        if ($null -eq $nameProp) { continue }
        $name = "$($nameProp.Value)"
        if (-not $inSet.ContainsKey($name)) { continue }
        $list = @()
        $depProp = $rec.PSObject.Properties['DependsOn']
        if ($null -ne $depProp) {
            $list = @($depProp.Value | Where-Object { $_ } | ForEach-Object { "$_" } |
                Where-Object { $inSet.ContainsKey($_) -and $_ -ne $name })
        }
        $deps[$name] = $list
    }
    $ordered = New-Object System.Collections.ArrayList
    $done = @{}
    $remaining = @($wanted)
    while ($remaining.Count -gt 0) {
        $ready = @()
        foreach ($n in $remaining) {
            $open = @()
            if ($deps.ContainsKey($n)) { $open = @($deps[$n] | Where-Object { -not $done.ContainsKey($_) }) }
            if ($open.Count -eq 0) { $ready += $n }
        }
        if ($ready.Count -eq 0) {
            $rest = [string[]]@($remaining)
            [Array]::Sort($rest, [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($n in $rest) { [void]$ordered.Add($n) }
            break
        }
        $wave = [string[]]@($ready)
        [Array]::Sort($wave, [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in $wave) {
            $done[$n] = $true
            [void]$ordered.Add($n)
        }
        $remaining = @($remaining | Where-Object { -not $done.ContainsKey($_) })
    }
    return [string[]]@($ordered)
}

# Stop the named services, bounded by TimeoutSec in total (spec 7.12). Never the Force switch:
# Windows must refuse to stop a service whose dependents still run, rather than
# cascade into a service outside the plan. That refusal is expected while the
# dependents are still stopping, so every poll (every 2 s) asks again for each
# service that is up and not already StopPending, which gives the updater's
# multi-pass stop order. The final state decides, not the request calls. A service
# that no longer exists counts as NotStopped, because the inventory changed.
function Stop-ServicesBounded {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]] $Names,
        [Parameter(Mandatory)][ValidateRange(0, 86400)][int] $TimeoutSec
    )
    $order = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($n in @($Names | Where-Object { $_ })) {
        if ($seen.ContainsKey("$n")) { continue }
        $seen["$n"] = $true
        [void]$order.Add("$n")
    }
    $requested = @{}
    $lastError = @{}
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $pending = 0
        foreach ($name in $order) {
            $svc = @(Get-Service -Name $name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
            if ($svc.Count -eq 0) { continue }
            $status = "$($svc[0].Status)"
            if ($status -eq 'Stopped') { continue }
            $pending++
            if ($status -eq 'StopPending') { continue }
            if (-not $requested.ContainsKey($name)) { Write-Log -Message "  stopping $name" -Level 'INFO' }
            $requested[$name] = $true
            try {
                Stop-Service -Name $name -NoWait -ErrorAction Stop
                $lastError.Remove($name)
            } catch {
                $lastError[$name] = "$($_.Exception.Message)"
            }
        }
        if ($pending -eq 0) { break }
        $remaining = $TimeoutSec - $timer.Elapsed.TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Milliseconds ([int][math]::Min(2000, [math]::Ceiling($remaining * 1000)))
    }
    $stopped = @()
    $notStopped = @()
    $problems = @()
    foreach ($name in $order) {
        $svc = @(Get-Service -Name $name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
        if ($svc.Count -eq 0) {
            $notStopped += $name
            $problems += "$name=missing"
            continue
        }
        $status = "$($svc[0].Status)"
        if ($status -eq 'Stopped') { $stopped += $name; continue }
        $notStopped += $name
        $why = "$name=$status"
        if ($lastError.ContainsKey($name)) { $why += " ($(Format-ShortText -Text $lastError[$name] -MaxLength 200))" }
        $problems += $why
    }
    if ($notStopped.Count -eq 0) {
        Write-Log -Message "Stopped $($stopped.Count) service(s) within ${TimeoutSec}s" -Level 'OK'
    } else {
        Write-Log -Message "Not stopped within ${TimeoutSec}s: $($problems -join '; ')" -Level 'WARN'
    }
    return [pscustomobject]@{
        Ok         = ($notStopped.Count -eq 0)
        Stopped    = [string[]]$stopped
        NotStopped = [string[]]$notStopped
    }
}

# Start the named services in the given order (use Get-StartOrder), bounded by
# TimeoutSec in total (spec 7.12): ServiceController.Start(), then WaitForStatus with
# the time that is left. Start() can throw while a slow service is in fact coming up
# (VBR 13 Backup Service), so the state read at the end decides. Each service gets
# its Start() request even when the time is used up, so nothing is left unasked.
function Start-ServicesBounded {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]] $Names,
        [Parameter(Mandatory)][ValidateRange(0, 86400)][int] $TimeoutSec
    )
    $order = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($n in @($Names | Where-Object { $_ })) {
        if ($seen.ContainsKey("$n")) { continue }
        $seen["$n"] = $true
        [void]$order.Add("$n")
    }
    $started = @()
    $notStarted = @()
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($name in $order) {
        $found = @(Get-Service -Name $name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
        if ($found.Count -eq 0) {
            Write-Log -Message "  cannot start ${name}: the service does not exist" -Level 'WARN'
            $notStarted += $name
            continue
        }
        $sc = $found[0]
        try { $sc.Refresh() } catch {}
        if ("$($sc.Status)" -eq 'Running') { $started += $name; continue }
        if ("$($sc.Status)" -eq 'StopPending') {
            $left = [math]::Max(0, $TimeoutSec - $timer.Elapsed.TotalSeconds)
            try { $sc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($left)) } catch {}
            try { $sc.Refresh() } catch {}
        }
        if ("$($sc.Status)" -eq 'Stopped') {
            Write-Log -Message "  starting $name" -Level 'INFO'
            try { $sc.Start() }
            catch { Write-Log -Message "  start request for $name reported: $(Format-ShortText -Text $_.Exception.Message -MaxLength 300)" -Level 'WARN' }
        }
        $left = [math]::Max(0, $TimeoutSec - $timer.Elapsed.TotalSeconds)
        try { $sc.WaitForStatus('Running', [TimeSpan]::FromSeconds($left)) } catch {}
        try { $sc.Refresh() } catch {}
        if ("$($sc.Status)" -eq 'Running') { $started += $name }
        else {
            Write-Log -Message "  $name is $($sc.Status), not Running" -Level 'WARN'
            $notStarted += $name
        }
    }
    if ($notStarted.Count -eq 0) {
        Write-Log -Message "Started $($started.Count) service(s) within ${TimeoutSec}s" -Level 'OK'
    } else {
        Write-Log -Message "Not running within ${TimeoutSec}s: $($notStarted -join ', ')" -Level 'WARN'
    }
    return [pscustomobject]@{
        Ok         = ($notStarted.Count -eq 0)
        Started    = [string[]]$started
        NotStarted = [string[]]$notStarted
    }
}

# True when the service is Running at every poll (every 5 s) for Seconds, including
# one last read at the end (Path B rollback settle, spec 7.6 rollback step 5).
function Test-ServiceStaysRunning {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][ValidateRange(0, 86400)][int] $Seconds
    )
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $svc = @(Get-Service -Name $Name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
        if ($svc.Count -eq 0) {
            Write-Log -Message "  $Name does not exist" -Level 'WARN'
            return $false
        }
        if ("$($svc[0].Status)" -ne 'Running') {
            Write-Log -Message "  $Name is $($svc[0].Status) after $([int]$timer.Elapsed.TotalSeconds)s" -Level 'WARN'
            return $false
        }
        $remaining = $Seconds - $timer.Elapsed.TotalSeconds
        if ($remaining -le 0) { return $true }
        Start-Sleep -Milliseconds ([int][math]::Min(5000, [math]::Ceiling($remaining * 1000)))
    }
}
#endregion Services

#region Registry
# Read each named value of one key as { Exists; Kind; Data }. Data is exactly what
# the registry holds (REG_EXPAND_SZ is not expanded), so a restore writes the same
# bytes back. A missing key reads as every value absent. Never log Data: for
# SqlSecuredPassword it is the DPAPI blob (spec 9).
function Get-RegistryValueSnapshot {
    param(
        [Parameter(Mandatory)][string] $KeyPath,
        [Parameter(Mandatory)][string[]] $Names
    )
    $result = @{}
    $item = Get-Item -LiteralPath $KeyPath -ErrorAction SilentlyContinue
    $present = @()
    if ($item) { $present = @($item.GetValueNames()) }
    foreach ($name in @($Names | Where-Object { $_ })) {
        if ($present -contains $name) {
            $result[$name] = [pscustomobject]@{
                Exists = $true
                Kind   = "$($item.GetValueKind($name))"
                Data   = $item.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        } else {
            $result[$name] = [pscustomobject]@{ Exists = $false; Kind = ''; Data = $null }
        }
    }
    return $result
}

# reg.exe wants HKLM\SOFTWARE\X where PowerShell uses HKLM:\SOFTWARE\X (HKCU is for the tests).
function ConvertTo-RegExePath {
    param([Parameter(Mandatory)][string] $KeyPath)
    $path = $KeyPath.Trim().TrimEnd('\')
    if ($path -match '^(?i)(HKLM|HKCU):\\(.+)$') { return ($Matches[1].ToUpperInvariant() + '\' + $Matches[2]) }
    if ($path -match '^(?i)(?:Microsoft\.PowerShell\.Core\\)?Registry::HKEY_LOCAL_MACHINE\\(.+)$') { return ('HKLM\' + $Matches[1]) }
    if ($path -match '^(?i)(?:Microsoft\.PowerShell\.Core\\)?Registry::HKEY_CURRENT_USER\\(.+)$') { return ('HKCU\' + $Matches[1]) }
    throw "Unsupported registry path for reg.exe: $KeyPath"
}

# Path B step 4: registry-before.json (every value the switch will change, with its
# old kind and data, or "absent") and a reg.exe export of ExportKeyPath, both in the
# protected run folder. No verified export means no change, so this throws.
function Save-RegistryBackup {
    param(
        [Parameter(Mandatory)][string] $KeyPath,
        [Parameter(Mandatory)][string] $ExportKeyPath,
        [Parameter(Mandatory)][string] $RunDir,
        [Parameter(Mandatory)][hashtable] $Snapshot
    )
    if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) { throw "Run folder $RunDir does not exist" }
    if ($ExportKeyPath -match '^(?i)(HKLM|HKCU)\\.+') { $nativeKey = $ExportKeyPath.Trim().TrimEnd('\') }
    else { $nativeKey = ConvertTo-RegExePath -KeyPath $ExportKeyPath }
    $jsonPath = Join-Path $RunDir 'registry-before.json'
    $regPath = Join-Path $RunDir 'vbr-key.reg'

    $values = [ordered]@{}
    foreach ($name in @($Snapshot.Keys | ForEach-Object { "$_" } | Sort-Object)) {
        $entry = $Snapshot[$name]
        if ($entry.Exists) {
            $values[$name] = [ordered]@{ State = 'present'; Kind = "$($entry.Kind)"; Data = $entry.Data }
        } else {
            $values[$name] = [ordered]@{ State = 'absent'; Kind = ''; Data = $null }
        }
    }
    $doc = [ordered]@{
        KeyPath   = $KeyPath
        ExportKey = $nativeKey
        RegExport = $regPath
        Time      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        Values    = $values
    }
    Write-AtomicJson -Path $jsonPath -Object $doc
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { throw "registry-before.json was not written to $RunDir" }

    if (Test-Path -LiteralPath $regPath) { Remove-Item -LiteralPath $regPath -Force -ErrorAction Stop }
    $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
    $export = Invoke-Native -FilePath $regExe -Arguments @('export', $nativeKey, $regPath, '/y')
    $length = 0
    if (Test-Path -LiteralPath $regPath -PathType Leaf) { $length = (Get-Item -LiteralPath $regPath).Length }
    if ($export.ExitCode -ne 0 -or $length -le 0) {
        throw "reg.exe export of $nativeKey failed (exit $($export.ExitCode), $length bytes): $(Format-ShortText -Text $export.StdErr -MaxLength 300)"
    }
    Write-Log -Message "Registry backup: $jsonPath and $regPath ($length bytes)" -Level 'OK'
    return [pscustomobject]@{ JsonPath = $jsonPath; RegPath = $regPath }
}

# The values the switch writes (spec 9). SqlUserName and SqlSecuredPassword always
# become empty Strings (DBConfig keeps them as empty values, so they are not deleted).
# PostgresUserForWindowsAuth only when it is not exactly 'postgres' (role names are
# case-sensitive). SqlHostName only when it is not already a loopback name.
function Get-RegistryTargets {
    param(
        [Parameter(Mandatory)] $DbConfig,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]] $Addresses
    )
    $targets = [ordered]@{}
    $targets['SqlUserName'] = ''
    $targets['SqlSecuredPassword'] = ''
    $role = "$(Get-CfgValue -Object $DbConfig -Name 'WindowsAuthRole' -Default '')"
    if ($role -cne 'postgres') { $targets['PostgresUserForWindowsAuth'] = 'postgres' }
    $hostName = "$(Get-CfgValue -Object $DbConfig -Name 'HostName' -Default '')"
    if (@('127.0.0.1', '::1', 'localhost') -notcontains $hostName) {
        $listening = @($Addresses | Where-Object { $_ })
        if ($listening -notcontains '127.0.0.1' -and $listening -contains '::1') { $targets['SqlHostName'] = '::1' }
        else { $targets['SqlHostName'] = '127.0.0.1' }
    }
    return $targets
}

# Path B step 8: write every target as a String, then read every one back. Values not
# in Targets (SqlLockInfo, SqlHostPort, SqlDatabaseName) are never touched.
function Set-RegistryTargets {
    param(
        [Parameter(Mandatory)][string] $KeyPath,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Targets
    )
    if (-not (Test-Path -LiteralPath $KeyPath)) { throw "Registry key $KeyPath does not exist" }
    $names = @($Targets.Keys | ForEach-Object { "$_" })
    foreach ($name in $names) {
        $value = [string]$Targets[$name]
        $null = New-ItemProperty -LiteralPath $KeyPath -Name $name -Value $value -PropertyType String -Force -ErrorAction Stop
        if ($name -like '*Password*') {
            if ($value) { $shown = '(set)' } else { $shown = '(empty)' }
        } else { $shown = "'$value'" }
        Write-Log -Message "  registry: $name = $shown" -Level 'INFO'
    }
    $after = Get-RegistryValueSnapshot -KeyPath $KeyPath -Names $names
    $wrong = @()
    foreach ($name in $names) {
        $have = $after[$name]
        if (-not $have.Exists -or "$($have.Kind)" -ne 'String' -or "$($have.Data)" -cne [string]$Targets[$name]) { $wrong += $name }
    }
    if ($wrong.Count -gt 0) { throw "Registry values did not read back as written: $($wrong -join ', ')" }
    Write-Log -Message "Registry switched: $($names -join ', ')" -Level 'OK'
}

# Path B rollback step 3 (spec 7.6): write each old value back with its old kind and
# delete each value that was absent, then read every value back and compare kind and
# data. If any differs, import the reg.exe export (it only adds and overwrites), delete
# the absent values again, and compare again. Returns $false, never throws, when the
# registry still differs; the caller turns that into exit 50.
function Restore-RegistrySnapshot {
    param(
        [Parameter(Mandatory)][string] $KeyPath,
        [Parameter(Mandatory)][hashtable] $Snapshot,
        [string] $RegExportPath = ''
    )
    $names = @($Snapshot.Keys | ForEach-Object { "$_" } | Sort-Object)
    $removeAbsent = {
        foreach ($name in $names) {
            if ($Snapshot[$name].Exists) { continue }
            try {
                $item = Get-Item -LiteralPath $KeyPath -ErrorAction SilentlyContinue
                if ($item -and (@($item.GetValueNames()) -contains $name)) {
                    Remove-ItemProperty -LiteralPath $KeyPath -Name $name -ErrorAction Stop
                }
            } catch {
                Write-Log -Message "  could not delete registry value ${name}: $(Format-ShortText -Text $_.Exception.Message -MaxLength 200)" -Level 'WARN'
            }
        }
    }
    $findWrong = {
        $current = Get-RegistryValueSnapshot -KeyPath $KeyPath -Names $names
        foreach ($name in $names) {
            $want = $Snapshot[$name]
            $have = $current[$name]
            if ([bool]$want.Exists -ne [bool]$have.Exists) { $name; continue }
            if (-not $want.Exists) { continue }
            if ("$($want.Kind)" -ne "$($have.Kind)") { $name; continue }
            $a = @($want.Data | ForEach-Object { "$_" })
            $b = @($have.Data | ForEach-Object { "$_" })
            if ($a.Count -ne $b.Count) { $name; continue }
            for ($i = 0; $i -lt $a.Count; $i++) {
                if ($a[$i] -cne $b[$i]) { $name; break }
            }
        }
    }
    try {
        foreach ($name in $names) {
            $entry = $Snapshot[$name]
            if (-not $entry.Exists) { continue }
            try {
                $null = New-ItemProperty -LiteralPath $KeyPath -Name $name -Value $entry.Data -PropertyType "$($entry.Kind)" -Force -ErrorAction Stop
            } catch {
                Write-Log -Message "  could not write registry value ${name}: $(Format-ShortText -Text $_.Exception.Message -MaxLength 200)" -Level 'WARN'
            }
        }
        & $removeAbsent
        $wrong = @(& $findWrong)
        if ($wrong.Count -eq 0) {
            Write-Log -Message 'Registry values restored from the snapshot' -Level 'OK'
            return $true
        }
        Write-Log -Message "Registry values still differ after the restore: $($wrong -join ', ')" -Level 'WARN'
        if (-not $RegExportPath -or -not (Test-Path -LiteralPath $RegExportPath -PathType Leaf)) {
            Write-Log -Message 'No reg.exe export to import; the registry was not restored' -Level 'ERROR'
            return $false
        }
        $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
        $import = Invoke-Native -FilePath $regExe -Arguments @('import', $RegExportPath)
        if ($import.ExitCode -ne 0) {
            Write-Log -Message "reg.exe import of $RegExportPath failed (exit $($import.ExitCode)): $(Format-ShortText -Text $import.StdErr -MaxLength 300)" -Level 'WARN'
        } else {
            Write-Log -Message "Imported the reg.exe export $RegExportPath" -Level 'INFO'
        }
        & $removeAbsent
        $wrong = @(& $findWrong)
        if ($wrong.Count -eq 0) {
            Write-Log -Message 'Registry values restored from the reg.exe export' -Level 'OK'
            return $true
        }
        Write-Log -Message "Registry values still differ after the reg.exe import: $($wrong -join ', ')" -Level 'ERROR'
        return $false
    } catch {
        Write-Log -Message "Registry restore failed: $(Format-ShortText -Text $_.Exception.Message -MaxLength 300)" -Level 'ERROR'
        return $false
    }
}
#endregion Registry

#region ConnectCheck
# Length of a file as the open stream sees it (0 when it is missing or cannot be
# opened). Full sharing, so Veeam can keep writing and rolling its log.
function Get-FileLength {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [long]0 }
    $stream = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = New-Object -TypeName System.IO.FileStream -ArgumentList @($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        return [long]$stream.Length
    } catch {
        return [long]0
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

# Lines written after FromOffset. If the file is now shorter than the offset (the
# log rolled over), the whole file is new. Decoded as UTF-8; the signatures we look
# for are ASCII. Empty lines are dropped. A file that cannot be opened or read (it
# was renamed after the Test-Path, it is held with no sharing, access is denied) is
# logged as a WARN and gives no lines, so the caller's next poll simply retries.
function Read-LogTail {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][long]   $FromOffset
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [string[]]@() }
    $stream = $null
    $buffer = $null
    $read = 0
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = New-Object -TypeName System.IO.FileStream -ArgumentList @($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $length = [long]$stream.Length
        $start = $FromOffset
        if ($start -lt 0 -or $start -gt $length) { $start = [long]0 }
        $size = [int]($length - $start)
        if ($size -le 0) { return [string[]]@() }
        $null = $stream.Seek($start, [IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] $size
        while ($read -lt $size) {
            $n = $stream.Read($buffer, $read, $size - $read)
            if ($n -le 0) { break }
            $read += $n
        }
    } catch {
        Write-Log -Message "Could not read the log tail of ${Path}: $(Format-ShortText -Text $_.Exception.Message -MaxLength 300)" -Level 'WARN'
        return [string[]]@()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    return [string[]]@($text -split '\r?\n' | Where-Object { $_ -ne '' })
}

# The spec 7.13 authentication-failure signatures. The SQLSTATE codes catch a
# server whose lc_messages is not English.
function Find-AuthErrors {
    param([AllowEmptyCollection()][string[]] $Lines)
    $pattern = 'SSPI authentication failed|no match in usermap|password authentication failed|no pg_hba\.conf entry|\b28000:|\b28P01:'
    return [string[]]@(@($Lines) | Where-Object { $null -ne $_ -and $_ -match $pattern })
}

# Spec 7.13 backend rule: a session that started after T, on the VBR database
# (case-insensitive), as postgres, from 127.0.0.1 or ::1. Get-PgLiveState already
# leaves out the script's own session. A local-time T is converted to UTC.
function Test-VbrConnectEvidence {
    param(
        [object[]] $Backends,
        [Parameter(Mandatory)][DateTime] $SinceUtc,
        [Parameter(Mandatory)][string]   $Database
    )
    $since = $SinceUtc
    if ($since.Kind -eq [DateTimeKind]::Local) { $since = $since.ToUniversalTime() }
    foreach ($backend in @($Backends)) {
        if ($null -eq $backend) { continue }
        $start = Get-CfgValue -Object $backend -Name 'BackendStartUtc' -Default $null
        if ($start -isnot [DateTime]) { continue }
        if ($start.Kind -eq [DateTimeKind]::Local) { $start = $start.ToUniversalTime() }
        if ($start -le $since) { continue }
        if ("$(Get-CfgValue -Object $backend -Name 'DatName' -Default '')" -ine $Database) { continue }
        if ("$(Get-CfgValue -Object $backend -Name 'UseName' -Default '')" -cne 'postgres') { continue }
        $address = "$(Get-CfgValue -Object $backend -Name 'ClientAddr' -Default '')".Trim()
        if ($address -ne '127.0.0.1' -and $address -ne '::1') { continue }
        return $true
    }
    return $false
}

# Spec 7.13: wait until the Backup Service runs and a new VBR session exists, and
# fail at once if Svc.VeeamBackup.log shows an authentication error after the
# offset. Each poll reads the whole tail from LogOffset, so a line cut in half by
# one read is still whole in the next.
function Wait-VbrDbConnected {
    param(
        [Parameter(Mandatory)][string]   $Psql,
        [Parameter(Mandatory)][int]      $Port,
        [Parameter(Mandatory)][string]   $Address,
        [Parameter(Mandatory)][string]   $Database,
        [Parameter(Mandatory)][DateTime] $SinceUtc,
        [Parameter(Mandatory)][int]      $TimeoutSec,
        [Parameter(Mandatory)][string]   $LogPath,
        [Parameter(Mandatory)][long]     $LogOffset,
        [int]    $PollSec = 10,
        [string] $ServiceName = 'VeeamBackupSvc'
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $polls = 0
    while ($true) {
        $polls++
        $missing = New-Object System.Collections.ArrayList
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        $status = 'missing'
        if ($null -ne $service) { $status = "$($service.Status)" }
        if ($status -ne 'Running') { [void]$missing.Add("$ServiceName is $status") }
        $live = Get-PgLiveState -Psql $Psql -Port $Port -Address $Address -Database $Database
        if (-not $live.Ok) {
            [void]$missing.Add('the SSPI query of pg_stat_activity failed')
        } elseif (-not (Test-VbrConnectEvidence -Backends @($live.Backends) -SinceUtc $SinceUtc -Database $Database)) {
            [void]$missing.Add("no new '$Database' session as postgres from loopback")
        }
        $authErrors = @(Find-AuthErrors -Lines @(Read-LogTail -Path $LogPath -FromOffset $LogOffset))
        if ($authErrors.Count -gt 0) {
            $detail = Format-ShortText -Text "Authentication error in $(Split-Path -Leaf $LogPath) after the services started: $($authErrors[0])" -MaxLength 400
            Write-Log -Message $detail -Level ERROR
            return [pscustomobject]@{ Ok = $false; Detail = $detail }
        }
        if ($missing.Count -eq 0) {
            $detail = "VBR connected to '$Database' as postgres over SSPI (check $polls)"
            Write-Log -Message $detail -Level OK
            return [pscustomobject]@{ Ok = $true; Detail = $detail }
        }
        if ((Get-Date) -ge $deadline) {
            $detail = "VBR did not connect to PostgreSQL within $TimeoutSec s: $($missing -join '; ')"
            Write-Log -Message $detail -Level ERROR
            return [pscustomobject]@{ Ok = $false; Detail = $detail }
        }
        Write-Log -Message "Waiting for VBR to connect (check $polls): $($missing -join '; ')" -Level INFO
        Start-Sleep -Seconds $PollSec
    }
}
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
