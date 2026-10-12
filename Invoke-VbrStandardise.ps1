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

# Reads the VBR database settings. Password values are reduced to "set or not"
# at once and never returned. Missing text values come back as ''. Port and
# EntraIdPort are [int] in 1-65535, otherwise $null.
function Get-VbrDbConfig {
    param([string] $RootKey = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication')
    $readPort = {
        param([string] $Key, [string] $Name)
        $raw = Get-RegValue -Path $Key -Name $Name
        $number = 0
        if ($null -ne $raw -and [int]::TryParse("$raw", [ref]$number) -and $number -ge 1 -and $number -le 65535) { return $number }
        return $null
    }
    $root = $RootKey.TrimEnd('\')
    $configKey = "$root\DatabaseConfigurations"
    $keyPath = "$configKey\PostgreSql"
    return [pscustomobject]@{
        RootKey             = $RootKey
        KeyPath             = $keyPath
        ActiveConfiguration = "$(Get-RegValue -Path $configKey -Name 'SqlActiveConfiguration')"
        HostName            = "$(Get-RegValue -Path $keyPath -Name 'SqlHostName')"
        Port                = (& $readPort $keyPath 'SqlHostPort')
        DatabaseName        = "$(Get-RegValue -Path $keyPath -Name 'SqlDatabaseName')"
        UserName            = "$(Get-RegValue -Path $keyPath -Name 'SqlUserName')"
        PasswordSet         = ("$(Get-RegValue -Path $keyPath -Name 'SqlSecuredPassword')".Length -gt 0)
        WindowsAuthRole     = "$(Get-RegValue -Path $keyPath -Name 'PostgresUserForWindowsAuth')"
        EntraIdHost         = "$(Get-RegValue -Path $root -Name 'EntraIdSqlHostName')"
        EntraIdPort         = (& $readPort $root 'EntraIdSqlHostPort')
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
    $rawPort = Get-RegValue -Path $keyPath -Name 'SqlHostPort'
    $number = 0
    $port = $null
    if ($null -ne $rawPort -and [int]::TryParse("$rawPort", [ref]$number) -and $number -ge 1 -and $number -le 65535) { $port = $number }
    return [pscustomobject]@{
        ActiveConfiguration = "$(Get-RegValue -Path $configKey -Name 'SqlActiveConfiguration')"
        HostName            = "$(Get-RegValue -Path $keyPath -Name 'SqlHostName')"
        Port                = $port
        PasswordSet         = ("$(Get-RegValue -Path $keyPath -Name 'SqlSecuredPassword')".Length -gt 0)
    }
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
    } catch { }
    try {
        $entry = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)
        [void]$candidates.Add($entry.HostName)
        foreach ($alias in @($entry.Aliases)) { [void]$candidates.Add($alias) }
    } catch { }
    try {
        foreach ($nic in @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces())) {
            foreach ($unicast in @($nic.GetIPProperties().UnicastAddresses)) {
                $text = $unicast.Address.ToString()
                [void]$candidates.Add($text)
                if ($text.Contains('%')) { [void]$candidates.Add($text.Split('%')[0]) }
            }
        }
    } catch { }
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
