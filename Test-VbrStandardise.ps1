# Tests for Invoke-VbrStandardise.ps1. Never copy this file to a VBR server or add it
# to the RMM.
#
# The harness parses Invoke-VbrStandardise.ps1, loads every top-level function through
# the AST and never runs the main body. Tests mock by redefining functions inside
# & { } child scopes, and use New-TestFolder folders and throwaway HKCU:\Software
# keys. They never create local users, change real services or write to HKLM.
#
# Run from an elevated prompt in the project folder:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1
# A pass ends with "RESULT: <n> passed, 0 failed" and exit code 0.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptPath = Join-Path $PSScriptRoot 'Invoke-VbrStandardise.ps1'
if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "FATAL: $ScriptPath not found."
    exit 1
}
$ScriptText = [System.IO.File]::ReadAllText($ScriptPath)
$parseTokens = $null
$parseErrors = $null
$ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    foreach ($parseError in $parseErrors) {
        Write-Host ("FATAL: parse error at line {0}: {1}" -f $parseError.Extent.StartLineNumber, $parseError.Message)
    }
    exit 1
}

# Load every top-level function at script scope. A foreach statement (not
# ForEach-Object) runs in this scope, so the dot-sourced definitions land here.
# The main body below the MAIN line never runs.
foreach ($topStatement in $ScriptAst.EndBlock.Statements) {
    if ($topStatement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($topStatement.Extent.Text))
    }
}

# ===================== HARNESS =====================
# Defined after the script's functions, so these definitions win.
$script:PassCount = 0
$script:FailCount = 0
$script:SkipCount = 0
$script:TestFolders = New-Object System.Collections.ArrayList
$script:TestFolderCount = 0
$script:LogLines = New-Object System.Collections.ArrayList

# Write-Log records "[LEVEL] message" instead of printing.
function Write-Log {
    param(
        [AllowEmptyString()][string] $Message = '',
        [string] $Level = 'INFO'
    )
    [void]$script:LogLines.Add("[$Level] $Message")
}

function Check {
    param([string] $Name, $Actual, $Expected)
    if ("$Actual" -ceq "$Expected") {
        $script:PassCount++
        Write-Host "  PASS  $Name"
    } else {
        $script:FailCount++
        Write-Host "  FAIL  $Name  expected '$Expected' got '$Actual'" -ForegroundColor Red
    }
}

function Throws {
    param([string] $Name, [scriptblock] $Block)
    $threw = $false
    try { $null = & $Block } catch { $threw = $true }
    if ($threw) {
        $script:PassCount++
        Write-Host "  PASS  $Name"
    } else {
        $script:FailCount++
        Write-Host "  FAIL  $Name  expected an exception, none was thrown" -ForegroundColor Red
    }
}

function Skip {
    param([string] $Name, [string] $Reason)
    $script:SkipCount++
    Write-Host "  SKIP  $Name  ($Reason)" -ForegroundColor Yellow
}

function New-TestFolder {
    param([string] $Tag = 'test')
    $script:TestFolderCount++
    $path = Join-Path $env:TEMP ('vbrstd-{0}-{1}-{2}' -f $Tag, $PID, $script:TestFolderCount)
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $path -Force)
    [void]$script:TestFolders.Add($path)
    return $path
}

# An error that escapes a test statement counts as one failure. The run goes on
# with the next statement, so one broken task cannot hide the other results.
trap {
    $script:FailCount++
    Write-Host ("  FAIL  UNHANDLED  {0}" -f $_.Exception.Message) -ForegroundColor Red
    continue
}

# --- Task 1: Project scaffold, test harness and core helpers ---
Write-Host '--- Task 1: Project scaffold, test harness and core helpers ---'

# Script skeleton: parameters, help, strict mode, regions, MAIN line.
$t1Params = @($ScriptAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Check 'T1 parameters are Apply, CreateServiceAccount, WorkRoot' ($t1Params -join ',') 'Apply,CreateServiceAccount,WorkRoot'
$t1WorkRootParam = @($ScriptAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'WorkRoot' })[0]
Check 'T1 WorkRoot default' $t1WorkRootParam.DefaultValue.Value 'C:\ProgramData\VeeamStandardise'
Check 'T1 script has [CmdletBinding()]' (@($ScriptAst.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }).Count) 1
$t1FirstTwo = @($ScriptAst.EndBlock.Statements | Select-Object -First 2 | ForEach-Object { $_.Extent.Text }) -join ' / '
Check 'T1 strict mode and Stop come first' $t1FirstTwo "Set-StrictMode -Version 2.0 / `$ErrorActionPreference = 'Stop'"
$t1Help = $ScriptAst.GetHelpContent()
Check 'T1 help is recognised' ($null -ne $t1Help) 'True'
Check 'T1 help has a synopsis' ([bool]$t1Help.Synopsis) 'True'
Check 'T1 help has a description' ([bool]$t1Help.Description) 'True'
Check 'T1 help documents the three parameters' ((@($t1Help.Parameters.Keys) | Sort-Object) -join ',') 'APPLY,CREATESERVICEACCOUNT,WORKROOT'
foreach ($t1Row in @('0 OK', '5 ACTION_NEEDED', '10 RETRY', '11 UNSUPPORTED', '20 PREFLIGHT', '40 ESCALATE', '50 ESCALATE_NOW')) {
    $t1Pattern = '(?m)^\s*' +($t1Row -replace ' ', '\s+') + '\s'
    Check "T1 help NOTES list exit code '$t1Row'" ($t1Help.Notes -match $t1Pattern) 'True'
}
Check 'T1 script is ASCII only' ($ScriptText -cmatch '[^\x00-\x7F]') 'False'

$t1RegionNames = @('Core', 'Outcome', 'Preflight', 'Vbr', 'PgDiscovery', 'Names', 'Account', 'ConfFiles', 'PgHba', 'PgIdent', 'Psql', 'State', 'Services', 'Registry', 'ConnectCheck', 'PathA', 'PathB', 'MainHelpers')
$t1Lines = $ScriptText -split "`r?`n"
$t1Markers = @($t1Lines | Where-Object { $_ -match '^#(end)?region\b' } | ForEach-Object { $_.TrimEnd() })
$t1ExpectedMarkers = @($t1RegionNames | ForEach-Object { "#region $_"; "#endregion $_" })
Check 'T1 regions open and close in order, never nested' ($t1Markers -join '|') ($t1ExpectedMarkers -join '|')
$t1MainLine = '# ===================== MAIN ====================='
Check 'T1 MAIN line appears once' (@($t1Lines | Where-Object { $_ -ceq $t1MainLine }).Count) 1
$t1MainNumber = [array]::IndexOf($t1Lines, $t1MainLine) + 1
$t1LastRegionNumber = [array]::IndexOf($t1Lines, '#endregion MainHelpers') + 1
Check 'T1 MAIN line follows the last region' ($t1MainNumber -gt $t1LastRegionNumber -and $t1LastRegionNumber -gt 0) 'True'
$t1Functions = @($ScriptAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
Check 'T1 no function below the MAIN line' (@($t1Functions | Where-Object { $_.Extent.StartLineNumber -gt $t1MainNumber }).Count) 0
$t1MarkerInfo = @(for ($t1i = 0; $t1i -lt $t1Lines.Count; $t1i++) {
    if ($t1Lines[$t1i] -match '^#(end)?region\b') { [pscustomobject]@{ Line = $t1i + 1; Text = $t1Lines[$t1i].TrimEnd() } }
})
$t1Outside = @(foreach ($t1Function in $t1Functions) {
    $t1Before = @($t1MarkerInfo | Where-Object { $_.Line -lt $t1Function.Extent.StartLineNumber } | Select-Object -Last 1)
    if ($t1Before.Count -eq 0 -or $t1Before[0].Text -notlike '#region *') { $t1Function.Name }
})
Check 'T1 every function sits inside a region' ($t1Outside -join ',') ''

# Harness self-checks.
[void]$script:LogLines.Clear()
Write-Log 'harness check' 'WARN'
Check 'T1 harness Write-Log records the line' (@($script:LogLines) -join '|') '[WARN] harness check'
[void]$script:LogLines.Clear()
$t1Folder = New-TestFolder 't1harness'
Check 'T1 New-TestFolder creates the folder' (Test-Path -LiteralPath $t1Folder -PathType Container) 'True'
Check 'T1 New-TestFolder name' ((Split-Path -Leaf $t1Folder) -match ('^vbrstd-t1harness-' + $PID + '-\d+$')) 'True'

# Get-DefaultConfig
$t1Cfg = Get-DefaultConfig
Check 'T1 config is a hashtable' ($t1Cfg -is [hashtable]) 'True'
Check 'T1 config has 8 settings' $t1Cfg.Count 8
Check 'T1 config ServiceAccountName' $t1Cfg.ServiceAccountName 'svc_veeam'
Check 'T1 config ServiceAccountDescription' $t1Cfg.ServiceAccountDescription 'Veeam maintenance account (PostgreSQL SSPI map)'
Check 'T1 config description is 48 characters or fewer' ($t1Cfg.ServiceAccountDescription.Length -le 48) 'True'
Check 'T1 config PasswordEnvVar' $t1Cfg.PasswordEnvVar 'VEEAM_SVC_PASSWORD'
Check 'T1 config ServiceStopTimeoutSec' $t1Cfg.ServiceStopTimeoutSec 300
Check 'T1 config VbrConnectTimeoutSec' $t1Cfg.VbrConnectTimeoutSec 600
Check 'T1 config RollbackSettleSec' $t1Cfg.RollbackSettleSec 300
Check 'T1 config BusyPersistentHours' $t1Cfg.BusyPersistentHours 6
Check 'T1 config RetentionDays' $t1Cfg.RetentionDays 30

# Get-ExitCodeTable
$t1Exit = Get-ExitCodeTable
Check 'T1 exit table is a hashtable' ($t1Exit -is [hashtable]) 'True'
Check 'T1 exit table has 7 codes' $t1Exit.Count 7
Check 'T1 exit codes' ('{0},{1},{2},{3},{4},{5},{6}' -f $t1Exit.OK, $t1Exit.ACTION_NEEDED, $t1Exit.RETRY, $t1Exit.UNSUPPORTED, $t1Exit.PREFLIGHT, $t1Exit.ESCALATE, $t1Exit.ESCALATE_NOW) '0,5,10,11,20,40,50'

# Write-Log (the real one, loaded into a child scope; the harness version is replaced there only)
$t1WriteLogAst = @($t1Functions | Where-Object { $_.Name -eq 'Write-Log' })
Check 'T1 script defines Write-Log' $t1WriteLogAst.Count 1
& {
    . ([scriptblock]::Create($t1WriteLogAst[0].Extent.Text))
    $t1Out = @(Write-Log -Message 'hello world' -Level 'WARN' 6>&1 | ForEach-Object { "$_" })
    Check 'T1 Write-Log line format' ($t1Out[-1] -cmatch '^\d{2}:\d{2}:\d{2} \[WARN \] hello world$') 'True'
    $t1Default = @(Write-Log 'plain' 6>&1 | ForEach-Object { "$_" })
    Check 'T1 Write-Log default level is INFO' ($t1Default[-1] -cmatch '^\d{2}:\d{2}:\d{2} \[INFO \] plain$') 'True'
    $t1Step = @(Write-Log 'next step' 'STEP' 6>&1 | ForEach-Object { "$_" })
    Check 'T1 Write-Log STEP prints a blank line first' ('{0}|{1}' -f $t1Step.Count, $t1Step[0]) '2|'
    $t1Empty = @(Write-Log '' 6>&1 | ForEach-Object { "$_" })
    Check 'T1 Write-Log accepts an empty message' ($t1Empty[-1] -cmatch '^\d{2}:\d{2}:\d{2} \[INFO \] $') 'True'
    Throws 'T1 Write-Log rejects an unknown level' { Write-Log -Message 'x' -Level 'DEBUG' }
}

# Format-ShortText
Check 'T1 Format-ShortText collapses whitespace' (Format-ShortText -Text "  a`r`n`tb   c  ") 'a b c'
Check 'T1 Format-ShortText empty text' (Format-ShortText -Text '') ''
Check 'T1 Format-ShortText null text' (Format-ShortText -Text $null) ''
$t1Long = Format-ShortText -Text ('x' * 1000)
Check 'T1 Format-ShortText default cap is 900' $t1Long.Length 900
Check 'T1 Format-ShortText cut text ends with three dots' $t1Long.EndsWith('...') 'True'
Check 'T1 Format-ShortText custom cap' (Format-ShortText -Text 'abcdefghij' -MaxLength 8) 'abcde...'
Check 'T1 Format-ShortText text at the cap is unchanged' (Format-ShortText -Text 'abcdefgh' -MaxLength 8) 'abcdefgh'

# Invoke-Native
$t1Cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
$t1Fail = Invoke-Native -FilePath $t1Cmd -Arguments @('/c', 'echo oops 1>&2 & exit /b 3')
Check 'T1 Invoke-Native returns the exit code' $t1Fail.ExitCode 3
Check 'T1 Invoke-Native exit code is int' ($t1Fail.ExitCode -is [int]) 'True'
Check 'T1 Invoke-Native returns clean stderr text' $t1Fail.StdErr 'oops'
Check 'T1 Invoke-Native stdout stays clean' $t1Fail.StdOut ''
$t1Ok = Invoke-Native -FilePath $t1Cmd -Arguments @('/c', 'echo one& echo two')
Check 'T1 Invoke-Native success exit code' $t1Ok.ExitCode 0
Check 'T1 Invoke-Native stdout lines' (($t1Ok.StdOut -split "`r?`n") -join ',') 'one,two'
Check 'T1 Invoke-Native success has no stderr' $t1Ok.StdErr ''
$t1In = Invoke-Native -FilePath $t1Cmd -Arguments @('/c', 'more') -StdinText "line1`nline2"
Check 'T1 Invoke-Native passes stdin' (($t1In.StdOut -split "`r?`n") -join ',') 'line1,line2'
$t1Missing = Invoke-Native -FilePath (Join-Path $env:TEMP "vbrstd-no-such-program-$PID.exe") -Arguments @('x')
Check 'T1 Invoke-Native missing program gives -1' $t1Missing.ExitCode -1
Check 'T1 Invoke-Native missing program explains' ($t1Missing.StdErr -like 'Could not run*') 'True'

# Get-RegValue (throwaway HKCU key)
$t1Key = "HKCU:\Software\VbrStdTest-T1-$PID"
try {
    [void](New-Item -Path $t1Key -Force)
    [void](New-ItemProperty -Path $t1Key -Name 'Str' -Value 'abc' -PropertyType String -Force)
    [void](New-ItemProperty -Path $t1Key -Name 'Num' -Value 5432 -PropertyType DWord -Force)
    [void](New-ItemProperty -Path $t1Key -Name 'Empty' -Value '' -PropertyType String -Force)
    Check 'T1 Get-RegValue string' (Get-RegValue -Path $t1Key -Name 'Str') 'abc'
    $t1Num = Get-RegValue -Path $t1Key -Name 'Num'
    Check 'T1 Get-RegValue DWord value' $t1Num 5432
    Check 'T1 Get-RegValue DWord is int' ($t1Num -is [int]) 'True'
    Check 'T1 Get-RegValue empty string is not null' ($null -ne (Get-RegValue -Path $t1Key -Name 'Empty')) 'True'
    Check 'T1 Get-RegValue missing value is null' ($null -eq (Get-RegValue -Path $t1Key -Name 'Nope')) 'True'
    Check 'T1 Get-RegValue missing key is null' ($null -eq (Get-RegValue -Path "$t1Key\NoSuchKey" -Name 'Str')) 'True'
} finally {
    Remove-Item -LiteralPath $t1Key -Recurse -Force -ErrorAction SilentlyContinue
}

# Get-CfgValue
$t1Obj = [pscustomobject]@{ A = 1; N = $null }
$t1Hash = @{ B = 'two'; Z = $null }
$t1Ordered = [ordered]@{ C = 3 }
Check 'T1 Get-CfgValue property' (Get-CfgValue -Object $t1Obj -Name 'A') 1
Check 'T1 Get-CfgValue missing property gives the default' (Get-CfgValue -Object $t1Obj -Name 'Q' -Default 9) 9
Check 'T1 Get-CfgValue null property is null, not the default' ($null -eq (Get-CfgValue -Object $t1Obj -Name 'N' -Default 9)) 'True'
Check 'T1 Get-CfgValue no default gives null' ($null -eq (Get-CfgValue -Object $t1Obj -Name 'Q')) 'True'
Check 'T1 Get-CfgValue hashtable key' (Get-CfgValue -Object $t1Hash -Name 'B') 'two'
Check 'T1 Get-CfgValue missing hashtable key' (Get-CfgValue -Object $t1Hash -Name 'Q' -Default 'd') 'd'
Check 'T1 Get-CfgValue hashtable Count is not a key' (Get-CfgValue -Object $t1Hash -Name 'Count' -Default 'd') 'd'
Check 'T1 Get-CfgValue null hashtable value' ($null -eq (Get-CfgValue -Object $t1Hash -Name 'Z' -Default 'd')) 'True'
Check 'T1 Get-CfgValue ordered key' (Get-CfgValue -Object $t1Ordered -Name 'C') 3
Check 'T1 Get-CfgValue null object' (Get-CfgValue -Object $null -Name 'A' -Default 7) 7

# ConvertFrom-JsonArrayText
Check 'T1 JSON empty array' (@(ConvertFrom-JsonArrayText -Text '[]').Count) 0
Check 'T1 JSON empty text' (@(ConvertFrom-JsonArrayText -Text '').Count) 0
Check 'T1 JSON null' (@(ConvertFrom-JsonArrayText -Text 'null').Count) 0
$t1One = @(ConvertFrom-JsonArrayText -Text '[{"pid":12,"usename":"postgres"}]')
Check 'T1 JSON one item' $t1One.Count 1
Check 'T1 JSON one item field' $t1One[0].usename 'postgres'
$t1Two = @(ConvertFrom-JsonArrayText -Text '[{"a":1},{"a":2}]')
Check 'T1 JSON two items' $t1Two.Count 2
Check 'T1 JSON second item field' $t1Two[1].a 2
Check 'T1 JSON scalar items' (@(ConvertFrom-JsonArrayText -Text '[1,2,3]') -join ',') '1,2,3'
$t1JsonErrorId = ''
try { $null = ConvertFrom-JsonArrayText -Text '[{' } catch { $t1JsonErrorId = $_.FullyQualifiedErrorId }
Check 'T1 JSON invalid text throws a JSON error' ($t1JsonErrorId -like '*ConvertFromJsonCommand') 'True'

# Write-AtomicText and Write-AtomicJson
$t1Dir = New-TestFolder 't1atomic'
$t1File = Join-Path $t1Dir 'sub\out.txt'
$t1Text = 'caf' + [char]0x00E9 + "`r`nline2"
Write-AtomicText -Path $t1File -Text $t1Text
Check 'T1 Write-AtomicText creates the parent folder' (Test-Path -LiteralPath $t1File) 'True'
$t1Bytes = [System.IO.File]::ReadAllBytes($t1File)
Check 'T1 Write-AtomicText writes no BOM' ($t1Bytes[0] -ne 0xEF) 'True'
Check 'T1 Write-AtomicText writes UTF-8 bytes' $t1Bytes.Length 12
Check 'T1 Write-AtomicText text round trip' ([System.Text.Encoding]::UTF8.GetString($t1Bytes) -ceq $t1Text) 'True'
Write-AtomicText -Path $t1File -Text 'second'
Check 'T1 Write-AtomicText replaces an existing file' ([System.IO.File]::ReadAllText($t1File)) 'second'
Check 'T1 Write-AtomicText leaves no temp file' (@(Get-ChildItem -LiteralPath (Join-Path $t1Dir 'sub') -Force).Count) 1
Write-AtomicText -Path $t1File -Text ''
Check 'T1 Write-AtomicText writes empty text' ((Get-Item -LiteralPath $t1File).Length) 0
$t1Json = Join-Path $t1Dir 'result.json'
Write-AtomicJson -Path $t1Json -Object ([ordered]@{ Name = 'x'; Number = 3; Nested = @{ Inner = @(1, 2) } })
$t1JsonBytes = [System.IO.File]::ReadAllBytes($t1Json)
Check 'T1 Write-AtomicJson writes no BOM' ($t1JsonBytes[0] -ne 0xEF) 'True'
$t1Back = [System.IO.File]::ReadAllText($t1Json) | ConvertFrom-Json
Check 'T1 Write-AtomicJson string field' $t1Back.Name 'x'
Check 'T1 Write-AtomicJson number field' $t1Back.Number 3
Check 'T1 Write-AtomicJson keeps nested arrays' (@($t1Back.Nested.Inner) -join ',') '1,2'

# --- Task 2: Run outcome, RMM summary and Complete-Run ---
Write-Host '--- Task 2: Run outcome, RMM summary and Complete-Run ---'

# New-RunReport
$t2Report = New-RunReport -Mode 'AUDIT'
Check 'T2 report is an ordered dictionary' ($t2Report -is [System.Collections.Specialized.OrderedDictionary]) 'True'
Check 'T2 report key order' (@($t2Report.Keys) -join ',') 'Computer,Timestamp,Mode,VbrVersion,PgMajor,SvcAccount,DbAuth,PgHba,PgIdent,PgPassword,Stage,Outcome,ExitCode,IssueCode,ActionRequired,Detail,LogPath'
Check 'T2 report Computer' $t2Report['Computer'] $env:COMPUTERNAME
Check 'T2 report Timestamp format' ($t2Report['Timestamp'] -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$') 'True'
Check 'T2 report Mode' $t2Report['Mode'] 'AUDIT'
Check 'T2 report Stage' $t2Report['Stage'] 'UNTOUCHED'
Check 'T2 report ExitCode is an empty string' ($t2Report['ExitCode'] -is [string] -and $t2Report['ExitCode'] -eq '') 'True'
foreach ($t2Key in @('SvcAccount', 'DbAuth', 'PgHba', 'PgIdent', 'PgPassword', 'Outcome')) {
    Check "T2 report $t2Key starts UNKNOWN" $t2Report[$t2Key] 'UNKNOWN'
}
foreach ($t2Key in @('VbrVersion', 'PgMajor', 'IssueCode', 'ActionRequired', 'Detail', 'LogPath')) {
    Check "T2 report $t2Key starts empty" ($t2Report[$t2Key] -is [string] -and $t2Report[$t2Key] -eq '') 'True'
}

# Add-RunIssue
Remove-Variable -Name Issues -Scope Script -ErrorAction SilentlyContinue
[void]$script:LogLines.Clear()
Add-RunIssue -Code 'SVC_ACCOUNT_MISSING' -ExitCode 5 -Detail 'svc_veeam does not exist' -Action 'Set RMM secure variable VEEAM_SVC_PASSWORD and re-run with -CreateServiceAccount'
Add-RunIssue -Code 'PG_HBA_NOT_STANDARD' -ExitCode 5
Check 'T2 Add-RunIssue creates an ArrayList' ($script:Issues -is [System.Collections.ArrayList]) 'True'
Check 'T2 Add-RunIssue appends' $script:Issues.Count 2
Check 'T2 Add-RunIssue Code' $script:Issues[0].Code 'SVC_ACCOUNT_MISSING'
Check 'T2 Add-RunIssue ExitCode is int' ($script:Issues[0].ExitCode -is [int]) 'True'
Check 'T2 Add-RunIssue Detail' $script:Issues[0].Detail 'svc_veeam does not exist'
Check 'T2 Add-RunIssue Action' $script:Issues[0].Action 'Set RMM secure variable VEEAM_SVC_PASSWORD and re-run with -CreateServiceAccount'
Check 'T2 Add-RunIssue default Detail' $script:Issues[1].Detail ''
Check 'T2 Add-RunIssue default Action' $script:Issues[1].Action ''
Check 'T2 Add-RunIssue logs the issue' (@($script:LogLines | Where-Object { $_ -like '`[WARN`] Issue PG_HBA_NOT_STANDARD (exit 5)*' }).Count) 1
$script:Issues = @([pscustomobject]@{ Code = 'OLD_ISSUE'; ExitCode = 5; Detail = ''; Action = '' })
Add-RunIssue -Code 'NEW_ISSUE' -ExitCode 10
Check 'T2 Add-RunIssue keeps items from a plain array' ((@($script:Issues) | ForEach-Object { $_.Code }) -join ',') 'OLD_ISSUE,NEW_ISSUE'
Remove-Variable -Name Issues -Scope Script -ErrorAction SilentlyContinue
[void]$script:LogLines.Clear()

# Get-RmmActionForExitCode
Check 'T2 action for 0 is None' (Get-RmmActionForExitCode -ExitCode 0) 'None'
$t2Actions = @(5, 10, 11, 20, 40, 50 | ForEach-Object { Get-RmmActionForExitCode -ExitCode $_ })
Check 'T2 each failure code has its own action' (@($t2Actions | Where-Object { $_ -and $_ -ne 'None' } | Select-Object -Unique).Count) 6
Check 'T2 action for 40 pages an operator' ((Get-RmmActionForExitCode -ExitCode 40) -clike 'PAGE AN OPERATOR. *') 'True'
Check 'T2 action for 50 pages an operator now' ((Get-RmmActionForExitCode -ExitCode 50) -clike 'PAGE AN OPERATOR NOW. *') 'True'
Check 'T2 action for an unknown code' (Get-RmmActionForExitCode -ExitCode 99) 'Investigate the undocumented exit code.'

# Resolve-RunOutcome
$t2None = Resolve-RunOutcome -Issues @()
Check 'T2 no issues' ('{0}|{1}|{2}|{3}' -f $t2None.ExitCode, $t2None.IssueCode, $t2None.ActionRequired, $t2None.Detail) '0||None|'
$t2Null = Resolve-RunOutcome -Issues $null
Check 'T2 null issues' ('{0}|{1}|{2}|{3}' -f $t2Null.ExitCode, $t2Null.IssueCode, $t2Null.ActionRequired, $t2Null.Detail) '0||None|'
$t2Issues = @(
    [pscustomobject]@{ Code = 'PG_HBA_NOT_STANDARD'; ExitCode = 5; Detail = 'two LAN lines'; Action = '' },
    [pscustomobject]@{ Code = 'VEEAM_BUSY'; ExitCode = 10; Detail = 'VeeamAgent.exe is running'; Action = '' },
    [pscustomobject]@{ Code = 'PG_IDENT_NOT_STANDARD'; ExitCode = 5; Detail = ''; Action = 'Custom action' }
)
$t2Outcome = Resolve-RunOutcome -Issues $t2Issues
Check 'T2 highest exit code wins' $t2Outcome.ExitCode 10
Check 'T2 outcome ExitCode is int' ($t2Outcome.ExitCode -is [int]) 'True'
Check 'T2 winner IssueCode' $t2Outcome.IssueCode 'VEEAM_BUSY'
Check 'T2 winner without Action gets the default' $t2Outcome.ActionRequired (Get-RmmActionForExitCode -ExitCode 10)
Check 'T2 Detail lists every issue' $t2Outcome.Detail 'PG_HBA_NOT_STANDARD: two LAN lines | VEEAM_BUSY: VeeamAgent.exe is running | PG_IDENT_NOT_STANDARD'
$t2Tie = Resolve-RunOutcome -Issues @($t2Issues[2], $t2Issues[0])
Check 'T2 tie goes to the earliest issue' $t2Tie.IssueCode 'PG_IDENT_NOT_STANDARD'
Check 'T2 winner Action is used' $t2Tie.ActionRequired 'Custom action'
$t2Hash = Resolve-RunOutcome -Issues @(@{ Code = 'MARKER_PRESENT'; ExitCode = 50; Detail = 'C:\ProgramData\VeeamStandardise\CHANGES-IN-PROGRESS.marker' })
Check 'T2 hashtable issues are accepted' ('{0} {1}' -f $t2Hash.ExitCode, $t2Hash.IssueCode) '50 MARKER_PRESENT'

# Format-RmmSummary
$t2Sum = [ordered]@{ Computer = 'HOST1'; Mode = 'AUDIT'; ExitCode = 5; IssueCode = 'PG_HBA_NOT_STANDARD'; ActionRequired = 'Run with -Apply'; Detail = "line one`r`n   line two" }
$t2Lines = @(Format-RmmSummary -Report $t2Sum)
Check 'T2 summary has 5 lines' $t2Lines.Count 5
Check 'T2 summary header' $t2Lines[0] '=== RMM SUMMARY ==='
Check 'T2 summary field line' $t2Lines[1] 'Computer=HOST1; Mode=AUDIT; ExitCode=5; IssueCode=PG_HBA_NOT_STANDARD; ActionRequired=Run with -Apply; Detail=line one line two'
Check 'T2 summary action line' $t2Lines[2] 'RMM ACTION: Run with -Apply'
Check 'T2 summary issue line' $t2Lines[3] 'RMM ISSUE: PG_HBA_NOT_STANDARD | line one line two'
Check 'T2 summary footer' $t2Lines[4] '==================='
$t2OkLines = @(Format-RmmSummary -Report ([ordered]@{ Computer = 'HOST1'; ExitCode = 0; IssueCode = ''; ActionRequired = 'None'; Detail = '' }))
Check 'T2 clean summary has no action or issue line' $t2OkLines.Count 3
Check 'T2 clean summary field line' $t2OkLines[1] 'Computer=HOST1; ExitCode=0; IssueCode=; ActionRequired=None; Detail='
$t2LongLines = @(Format-RmmSummary -Report ([ordered]@{ Detail = ('y' * 2000) }))
Check 'T2 summary values are capped at 900' $t2LongLines[1].Length 907
Check 'T2 summary of a new report starts with Computer' (@(Format-RmmSummary -Report (New-RunReport -Mode 'AUDIT'))[1] -clike 'Computer=*; LogPath=') 'True'

# Get-TrapAction
Check 'T2 trap action UNTOUCHED' (Get-TrapAction -Stage 'UNTOUCHED') 'EXIT_UNHANDLED'
Check 'T2 trap action PATH_A_WRITING' (Get-TrapAction -Stage 'PATH_A_WRITING') 'RESTORE_PATH_A'
Check 'T2 trap action PATH_A_DONE' (Get-TrapAction -Stage 'PATH_A_DONE') 'NO_ROLLBACK'
Check 'T2 trap action VERIFIED' (Get-TrapAction -Stage 'VERIFIED') 'NO_ROLLBACK'
Check 'T2 trap action PATH_B_CHANGING' (Get-TrapAction -Stage 'PATH_B_CHANGING') 'ROLLBACK_PATH_B'
Check 'T2 trap action unknown stage' (Get-TrapAction -Stage 'SOMETHING_ELSE') 'EXIT_UNHANDLED'
Check 'T2 trap action empty stage' (Get-TrapAction -Stage '') 'EXIT_UNHANDLED'

# Complete-Run exits the process, so it runs in a child powershell.exe. The driver
# holds the real function texts from $ScriptAst plus a stand-in for Exit-RunLock
# (Task 3) that records the release.
$t2Fn = @{}
foreach ($t2Statement in $ScriptAst.EndBlock.Statements) {
    if ($t2Statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        $t2Fn[$t2Statement.Name] = $t2Statement.Extent.Text
    }
}
$t2Needed = @('Format-ShortText', 'Write-Log', 'Write-AtomicText', 'Write-AtomicJson', 'Get-CfgValue', 'New-RunReport', 'Add-RunIssue', 'Get-RmmActionForExitCode', 'Resolve-RunOutcome', 'Format-RmmSummary', 'Complete-Run')
Check 'T2 driver functions exist in the script' (@($t2Needed | Where-Object { -not $t2Fn.ContainsKey($_) }) -join ',') ''
$t2DriverHead = @'
param([string] $Scenario, [string] $Root)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
function Exit-RunLock {
    param($Mutex)
    [System.IO.File]::WriteAllText((Join-Path $Root 'lock-released.txt'), [string]$Mutex)
}
'@
$t2DriverBody = @'
$WorkRoot = $Root
switch ($Scenario) {
    'issues' {
        $script:Report = New-RunReport -Mode 'APPLY'
        $script:Stage = 'PATH_A_DONE'
        $script:WorkRootReady = $true
        $script:RunLock = 'fake-lock'
        Start-Transcript -LiteralPath (Join-Path $Root 'transcript.log') | Out-Null
        $script:TranscriptStarted = $true
        Add-RunIssue -Code 'PG_HBA_NOT_STANDARD' -ExitCode 5 -Detail 'two LAN lines'
        Complete-Run -ExitCode 10 -Code 'VEEAM_BUSY' -Detail 'VeeamAgent.exe is running' -Action 'Retry after the running job ends'
    }
    'bare' {
        Complete-Run -ExitCode 20 -Code 'VBR_NOT_FOUND' -Detail 'No VBR server install found'
    }
    'clean' {
        $script:Report = New-RunReport -Mode 'AUDIT'
        $script:WorkRootReady = $true
        Complete-Run
    }
}
Write-Host 'AFTER-COMPLETE-RUN'
'@
$t2FunctionText = (@($t2Needed | Where-Object { $t2Fn.ContainsKey($_) } | ForEach-Object { $t2Fn[$_] }) -join "`r`n`r`n")
$t2DriverDir = New-TestFolder 't2driver'
$t2DriverPath = Join-Path $t2DriverDir 'driver.ps1'
[System.IO.File]::WriteAllText($t2DriverPath, ($t2DriverHead + "`r`n" + $t2FunctionText + "`r`n" + $t2DriverBody), (New-Object System.Text.UTF8Encoding -ArgumentList $false))
$t2PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Scenario 'issues': two issues, a transcript, a lock, a ready WorkRoot.
$t2RootA = New-TestFolder 't2issues'
$t2A = Invoke-Native -FilePath $t2PowerShell -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $t2DriverPath, '-Scenario', 'issues', '-Root', $t2RootA)
$t2ALines = @($t2A.StdOut -split "`r?`n")
$t2ASummary = @($t2ALines | Where-Object { $_ -clike 'Computer=*' })
Check 'T2 issues: exit code is the highest issue' $t2A.ExitCode 10
Check 'T2 issues: no errors on stderr' $t2A.StdErr ''
Check 'T2 issues: one summary line' $t2ASummary.Count 1
Check 'T2 issues: summary Mode' ($t2ASummary[0] -clike '*; Mode=APPLY; *') 'True'
Check 'T2 issues: summary Stage from $script:Stage' ($t2ASummary[0] -clike '*; Stage=PATH_A_DONE; *') 'True'
Check 'T2 issues: summary Outcome' ($t2ASummary[0] -clike '*; Outcome=VEEAM_BUSY; *') 'True'
Check 'T2 issues: summary ExitCode' ($t2ASummary[0] -clike '*; ExitCode=10; *') 'True'
Check 'T2 issues: summary IssueCode' ($t2ASummary[0] -clike '*; IssueCode=VEEAM_BUSY; *') 'True'
Check 'T2 issues: header before the field line' ([array]::IndexOf($t2ALines, '=== RMM SUMMARY ===') -eq ([array]::IndexOf($t2ALines, $t2ASummary[0]) - 1)) 'True'
Check 'T2 issues: RMM ACTION line' (@($t2ALines | Where-Object { $_ -ceq 'RMM ACTION: Retry after the running job ends' }).Count) 1
Check 'T2 issues: RMM ISSUE line' (@($t2ALines | Where-Object { $_ -ceq 'RMM ISSUE: VEEAM_BUSY | PG_HBA_NOT_STANDARD: two LAN lines | VEEAM_BUSY: VeeamAgent.exe is running' }).Count) 1
Check 'T2 issues: footer is the last summary line' ($t2ALines[-1]) '==================='
Check 'T2 issues: Complete-Run exits and does not return' ('{0}|{1}' -f $t2A.ExitCode, ($t2A.StdOut -clike '*AFTER-COMPLETE-RUN*')) '10|False'
$t2AJsonPath = Join-Path $t2RootA 'logs\last-result.json'
Check 'T2 issues: last-result.json written' (Test-Path -LiteralPath $t2AJsonPath) 'True'
Check 'T2 issues: last-result.json has no BOM' ([System.IO.File]::ReadAllBytes($t2AJsonPath)[0] -ne 0xEF) 'True'
$t2AJson = [System.IO.File]::ReadAllText($t2AJsonPath) | ConvertFrom-Json
Check 'T2 issues: last-result.json ExitCode' $t2AJson.ExitCode 10
Check 'T2 issues: last-result.json IssueCode' $t2AJson.IssueCode 'VEEAM_BUSY'
Check 'T2 issues: last-result.json Stage' $t2AJson.Stage 'PATH_A_DONE'
Check 'T2 issues: lock released with $script:RunLock' ([System.IO.File]::ReadAllText((Join-Path $t2RootA 'lock-released.txt'))) 'fake-lock'
$t2Transcript = [System.IO.File]::ReadAllText((Join-Path $t2RootA 'transcript.log'))
Check 'T2 issues: summary is in the transcript' ($t2Transcript -like '*=== RMM SUMMARY ===*') 'True'
Check 'T2 issues: transcript was stopped' ($t2Transcript -like '*transcript end*') 'True'

# Scenario 'bare': no Report, Stage, Issues, WorkRootReady, transcript or lock exist.
$t2RootB = New-TestFolder 't2bare'
$t2B = Invoke-Native -FilePath $t2PowerShell -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $t2DriverPath, '-Scenario', 'bare', '-Root', $t2RootB)
$t2BLines = @($t2B.StdOut -split "`r?`n")
$t2BSummary = @($t2BLines | Where-Object { $_ -clike 'Computer=*' })
Check 'T2 bare: exit code' $t2B.ExitCode 20
Check 'T2 bare: no StrictMode errors on stderr' $t2B.StdErr ''
Check 'T2 bare: one summary line' $t2BSummary.Count 1
Check 'T2 bare: Mode UNKNOWN, Stage UNTOUCHED' ($t2BSummary[0] -clike '*; Mode=UNKNOWN; *; Stage=UNTOUCHED; Outcome=VBR_NOT_FOUND; ExitCode=20; IssueCode=VBR_NOT_FOUND; *') 'True'
Check 'T2 bare: default action for 20' (@($t2BLines | Where-Object { $_ -ceq ('RMM ACTION: ' + (Get-RmmActionForExitCode -ExitCode 20)) }).Count) 1
Check 'T2 bare: RMM ISSUE line' (@($t2BLines | Where-Object { $_ -ceq 'RMM ISSUE: VBR_NOT_FOUND | VBR_NOT_FOUND: No VBR server install found' }).Count) 1
Check 'T2 bare: no last-result.json without a ready WorkRoot' ('{0}|{1}' -f $t2B.ExitCode, (Test-Path -LiteralPath (Join-Path $t2RootB 'logs\last-result.json'))) '20|False'
Check 'T2 bare: no lock to release' ('{0}|{1}' -f $t2B.ExitCode, (Test-Path -LiteralPath (Join-Path $t2RootB 'lock-released.txt'))) '20|False'
Check 'T2 bare: Complete-Run exits and does not return' ('{0}|{1}' -f $t2B.ExitCode, ($t2B.StdOut -clike '*AFTER-COMPLETE-RUN*')) '20|False'

# Scenario 'clean': no issues.
$t2RootC = New-TestFolder 't2clean'
$t2C = Invoke-Native -FilePath $t2PowerShell -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $t2DriverPath, '-Scenario', 'clean', '-Root', $t2RootC)
$t2CLines = @($t2C.StdOut -split "`r?`n")
$t2CSummary = @($t2CLines | Where-Object { $_ -clike 'Computer=*' })
Check 'T2 clean: exit code 0' $t2C.ExitCode 0
Check 'T2 clean: one summary line' $t2CSummary.Count 1
Check 'T2 clean: Outcome OK' ($t2CSummary[0] -clike '*; Outcome=OK; ExitCode=0; IssueCode=; ActionRequired=None; Detail=; *') 'True'
Check 'T2 clean: no RMM ACTION or RMM ISSUE line' ('{0}|{1}' -f $t2CSummary.Count, @($t2CLines | Where-Object { $_ -clike 'RMM ACTION:*' -or $_ -clike 'RMM ISSUE:*' }).Count) '1|0'
$t2CJsonPath = Join-Path $t2RootC 'logs\last-result.json'
Check 'T2 clean: last-result.json written' (Test-Path -LiteralPath $t2CJsonPath) 'True'
$t2CJson = [System.IO.File]::ReadAllText($t2CJsonPath) | ConvertFrom-Json
Check 'T2 clean: last-result.json Outcome' ('{0} {1}' -f $t2CJson.Outcome, $t2CJson.ExitCode) 'OK 0'
# --- Task 3: Host preflight, work root, lock and markers ---
$t3IsAdmin = (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
$t3PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$t3FnAst = @{}
foreach ($t3Node in $ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $t3FnAst[$t3Node.Name] = $t3Node }
$t3ChildDir = New-TestFolder 'child'
$t3ChildCount = 0
# Runs code in a separate powershell.exe and returns its output as one string.
$t3RunChild = {
    param([string] $Code)
    $script:t3ChildCount++
    $file = Join-Path $t3ChildDir "child-$($script:t3ChildCount).ps1"
    [IO.File]::WriteAllText($file, "`$ProgressPreference = 'SilentlyContinue'`r`n" + $Code, (New-Object System.Text.UTF8Encoding($true)))
    $output = & $t3PsExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file
    return ((@($output) -join "`n").Trim())
}
$t3ParamDefault = {
    param([string] $Function, [string] $Parameter)
    $p = @($t3FnAst[$Function].Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Parameter })
    if ($p.Count -ne 1 -or $null -eq $p[0].DefaultValue) { return '' }
    return $p[0].DefaultValue.Extent.Text
}
# Makes a test file look like one the script wrote as SYSTEM: owner Administrators.
$t3SetOwnerAdmins = {
    param([string] $Path)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
$t3AllowEveryoneWrite = {
    param([string] $Path)
    $acl = Get-Acl -LiteralPath $Path
    $everyone = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($everyone, 'Write', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# Test-IsAdministrator
Check 'Test-IsAdministrator: returns a bool' ((Test-IsAdministrator) -is [bool]) 'True'
Check 'Test-IsAdministrator: matches the process token' (Test-IsAdministrator) "$t3IsAdmin"

# Get-PreflightContextIssue: order WRONG_POWERSHELL, NOT_ELEVATED, HOST_32BIT, CONSTRAINED_LANGUAGE
$t3I = Get-PreflightContextIssue -PSEdition 'Desktop' -IsAdmin $true -Is64BitOS $true -Is64BitProcess $true -LanguageMode 'FullLanguage'
Check 'preflight context: all good gives no issue' ($null -eq $t3I) 'True'
$t3I = Get-PreflightContextIssue -PSEdition 'Core' -IsAdmin $true -Is64BitOS $true -Is64BitProcess $true -LanguageMode 'FullLanguage'
Check 'preflight context: Core edition is WRONG_POWERSHELL' $t3I.Code 'WRONG_POWERSHELL'
Check 'preflight context: WRONG_POWERSHELL exits 20' $t3I.ExitCode 20
Check 'preflight context: WRONG_POWERSHELL action names powershell.exe' $t3I.Action 'Run %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
Check 'preflight context: issue shape' (@($t3I.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') 'Code,ExitCode,Detail,Action'
$t3I = Get-PreflightContextIssue -PSEdition 'Desktop' -IsAdmin $false -Is64BitOS $true -Is64BitProcess $true -LanguageMode 'FullLanguage'
Check 'preflight context: not elevated is NOT_ELEVATED' $t3I.Code 'NOT_ELEVATED'
Check 'preflight context: NOT_ELEVATED exits 20' $t3I.ExitCode 20
$t3I = Get-PreflightContextIssue -PSEdition 'Desktop' -IsAdmin $true -Is64BitOS $true -Is64BitProcess $false -LanguageMode 'FullLanguage'
Check 'preflight context: 32-bit process on 64-bit OS is HOST_32BIT' $t3I.Code 'HOST_32BIT'
Check 'preflight context: HOST_32BIT exits 20' $t3I.ExitCode 20
$t3I = Get-PreflightContextIssue -PSEdition 'Desktop' -IsAdmin $true -Is64BitOS $false -Is64BitProcess $false -LanguageMode 'FullLanguage'
Check 'preflight context: 32-bit process on 32-bit OS is not HOST_32BIT' ($null -eq $t3I) 'True'
$t3I = Get-PreflightContextIssue -PSEdition 'Desktop' -IsAdmin $true -Is64BitOS $true -Is64BitProcess $true -LanguageMode 'ConstrainedLanguage'
Check 'preflight context: ConstrainedLanguage is CONSTRAINED_LANGUAGE' $t3I.Code 'CONSTRAINED_LANGUAGE'
Check 'preflight context: CONSTRAINED_LANGUAGE exits 20' $t3I.ExitCode 20
$t3I = Get-PreflightContextIssue -PSEdition 'Desktop' -IsAdmin $true -Is64BitOS $true -Is64BitProcess $true -LanguageMode 'RestrictedLanguage'
Check 'preflight context: RestrictedLanguage is CONSTRAINED_LANGUAGE' $t3I.Code 'CONSTRAINED_LANGUAGE'
$t3I = Get-PreflightContextIssue -PSEdition 'Core' -IsAdmin $false -Is64BitOS $true -Is64BitProcess $false -LanguageMode 'ConstrainedLanguage'
Check 'preflight context: edition is checked first' $t3I.Code 'WRONG_POWERSHELL'
$t3I = Get-PreflightContextIssue -PSEdition 'Desktop' -IsAdmin $false -Is64BitOS $true -Is64BitProcess $false -LanguageMode 'ConstrainedLanguage'
Check 'preflight context: elevation is checked before bitness' $t3I.Code 'NOT_ELEVATED'
$t3I = Get-PreflightContextIssue -PSEdition 'Desktop' -IsAdmin $true -Is64BitOS $true -Is64BitProcess $false -LanguageMode 'ConstrainedLanguage'
Check 'preflight context: bitness is checked before language mode' $t3I.Code 'HOST_32BIT'

# Enter-RunLock / Exit-RunLock (a Local\ test name, so no elevation is needed)
Check 'Enter-RunLock: default name is the updater mutex' (& $t3ParamDefault 'Enter-RunLock' 'Name') "'Global\VeeamPgUpdate'"
$t3LockName = "Local\VbrStdTest-$PID"
$t3ChildLock = @(
    'function Write-Log { param([string] $Message, [string] $Level = ''INFO'') }',
    $t3FnAst['Enter-RunLock'].Extent.Text,
    $t3FnAst['Exit-RunLock'].Extent.Text,
    "`$m = Enter-RunLock -Name '$t3LockName'",
    "if (`$null -eq `$m) { 'NOT_ACQUIRED' } else { 'ACQUIRED'; Exit-RunLock -Mutex `$m }"
) -join "`n"
$t3Lock = Enter-RunLock -Name $t3LockName
try {
    Check 'Enter-RunLock: free lock is acquired' ($t3Lock -is [System.Threading.Mutex]) 'True'
    Check 'Enter-RunLock: second process does not get a held lock' (& $t3RunChild $t3ChildLock) 'NOT_ACQUIRED'
} finally {
    Exit-RunLock -Mutex $t3Lock
}
Check 'Exit-RunLock: released lock can be taken by another process' (& $t3RunChild $t3ChildLock) 'ACQUIRED'
$t3Threw = $false
try { Exit-RunLock -Mutex $t3Lock; Exit-RunLock -Mutex $null } catch { $t3Threw = $true }
Check 'Exit-RunLock: disposed or null mutex never throws' $t3Threw 'False'
$t3AbandonName = "Local\VbrStdTest-abandoned-$PID"
$t3Holder = New-Object System.Threading.Mutex($false, $t3AbandonName)
try {
    $t3Took = & $t3RunChild "`$m = New-Object System.Threading.Mutex(`$false, '$t3AbandonName'); if (`$m.WaitOne(0)) { 'TOOK' }"
    Check 'Enter-RunLock fixture: child took the lock and exited without release' $t3Took 'TOOK'
    $t3LogStart = $script:LogLines.Count
    $t3Abandoned = Enter-RunLock -Name $t3AbandonName
    Check 'Enter-RunLock: abandoned lock counts as acquired' ($t3Abandoned -is [System.Threading.Mutex]) 'True'
    Check 'Enter-RunLock: abandoned lock is logged' (@($script:LogLines | Select-Object -Skip $t3LogStart | Where-Object { $_ -like '*abandoned*' }).Count) 1
    Exit-RunLock -Mutex $t3Abandoned
} finally {
    $t3Holder.Dispose()
}

# Test-IsDomainController (Win32_OperatingSystem mocked)
Check 'Test-IsDomainController: ProductType 2 is a DC' (& {
    function Get-CimInstance { [CmdletBinding()] param([string] $ClassName) [pscustomobject]@{ ProductType = [uint32]2 } }
    Test-IsDomainController }) 'True'
Check 'Test-IsDomainController: ProductType 3 is a member server' (& {
    function Get-CimInstance { [CmdletBinding()] param([string] $ClassName) [pscustomobject]@{ ProductType = [uint32]3 } }
    Test-IsDomainController }) 'False'
Check 'Test-IsDomainController: ProductType 1 is a workstation' (& {
    function Get-CimInstance { [CmdletBinding()] param([string] $ClassName) [pscustomobject]@{ ProductType = [uint32]1 } }
    Test-IsDomainController }) 'False'
Check 'Test-IsDomainController: asks for Win32_OperatingSystem' (& {
    function Get-CimInstance { [CmdletBinding()] param([string] $ClassName) [pscustomobject]@{ ProductType = $(if ($ClassName -eq 'Win32_OperatingSystem') { 2 } else { 0 }) } }
    Test-IsDomainController }) 'True'

# Initialize-WorkRoot: refusals that need no elevation
$t3R = Initialize-WorkRoot -Path 'C:\'
Check 'Initialize-WorkRoot: drive root is refused' $t3R.Ok 'False'
Check 'Initialize-WorkRoot: drive root says why' ($t3R.Detail -match 'root of a drive') 'True'
Check 'Initialize-WorkRoot: result shape' (@($t3R.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') 'Ok,Detail'
$t3Missing = Join-Path (New-TestFolder 'wrmiss') 'no-such-parent'
$t3R = Initialize-WorkRoot -Path (Join-Path $t3Missing 'root')
Check 'Initialize-WorkRoot: missing parent is refused' $t3R.Ok 'False'
Check 'Initialize-WorkRoot: missing parent is not created' (Test-Path -LiteralPath $t3Missing) 'False'

# Find-ChangeMarkers, New-RunFolder, markers and last failure (no elevation needed)
$t3FindDefault = & $t3ParamDefault 'Find-ChangeMarkers' 'UpdaterPaths'
$t3UpdIndex = $t3FindDefault.IndexOf('C:\ProgramData\VeeamPgUpdate\CHANGES-IN-PROGRESS.marker')
$t3LegIndex = $t3FindDefault.IndexOf('C:\temp\VeeamPgUpdate\CHANGES-IN-PROGRESS.marker')
Check 'Find-ChangeMarkers: default checks the updater marker first' ($t3UpdIndex -ge 0 -and $t3LegIndex -gt $t3UpdIndex) 'True'
$t3Wr = New-TestFolder 'mk'
$t3Upd = New-TestFolder 'mkupd'
$t3UpdCurrent = Join-Path $t3Upd 'current\CHANGES-IN-PROGRESS.marker'
$t3UpdLegacy = Join-Path $t3Upd 'legacy\CHANGES-IN-PROGRESS.marker'
$t3Own = Join-Path $t3Wr 'CHANGES-IN-PROGRESS.marker'
Check 'Find-ChangeMarkers: none present' (@(Find-ChangeMarkers -WorkRoot $t3Wr -UpdaterPaths @($t3UpdCurrent, $t3UpdLegacy)).Count) 0

$t3Run = New-RunFolder -WorkRoot $t3Wr -Stamp '20261012-101500'
Check 'New-RunFolder: path is <WorkRoot>\runs\<Stamp>' $t3Run (Join-Path $t3Wr 'runs\20261012-101500')
Check 'New-RunFolder: folder exists' (Test-Path -LiteralPath $t3Run -PathType Container) 'True'
Throws 'New-RunFolder: an existing run folder is refused' { New-RunFolder -WorkRoot $t3Wr -Stamp '20261012-101500' }
Throws 'New-RunFolder: a stamp with a path separator is refused' { New-RunFolder -WorkRoot $t3Wr -Stamp '..\escape' }

Write-ChangeMarker -WorkRoot $t3Wr -RunDir $t3Run -PathName 'B' -Stage 'PATH_B_CHANGING'
Check 'Write-ChangeMarker: marker exists' (Test-Path -LiteralPath $t3Own -PathType Leaf) 'True'
$t3Bytes = [IO.File]::ReadAllBytes($t3Own)
Check 'Write-ChangeMarker: no BOM' ($t3Bytes.Length -gt 0 -and $t3Bytes[0] -ne 0xEF) 'True'
$t3Json = [IO.File]::ReadAllText($t3Own) | ConvertFrom-Json
Check 'Write-ChangeMarker: RunDir' (Get-CfgValue -Object $t3Json -Name 'RunDir') $t3Run
Check 'Write-ChangeMarker: Path' (Get-CfgValue -Object $t3Json -Name 'Path') 'B'
Check 'Write-ChangeMarker: Stage' (Get-CfgValue -Object $t3Json -Name 'Stage') 'PATH_B_CHANGING'
Check 'Write-ChangeMarker: Time' ([IO.File]::ReadAllText($t3Own) -match '"Time"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}') 'True'

$t3Found = @(Find-ChangeMarkers -WorkRoot $t3Wr -UpdaterPaths @($t3UpdCurrent, $t3UpdLegacy))
Check 'Find-ChangeMarkers: own marker found' ($t3Found -join '|') $t3Own
$t3Found = @(Find-ChangeMarkers -WorkRoot $t3Wr -UpdaterPaths @($t3Own, $t3UpdLegacy))
Check 'Find-ChangeMarkers: a path is listed once' $t3Found.Count 1
Check 'Remove-ChangeMarker: returns true' (Remove-ChangeMarker -WorkRoot $t3Wr) 'True'
Check 'Remove-ChangeMarker: marker is gone' (Test-Path -LiteralPath $t3Own) 'False'
Check 'Remove-ChangeMarker: absent marker is true' (Remove-ChangeMarker -WorkRoot $t3Wr) 'True'

[void][IO.Directory]::CreateDirectory((Split-Path -Parent $t3UpdCurrent))
[IO.File]::WriteAllText($t3UpdCurrent, '{}')
Check 'Find-ChangeMarkers: updater marker found' ((@(Find-ChangeMarkers -WorkRoot $t3Wr -UpdaterPaths @($t3UpdCurrent, $t3UpdLegacy))) -join '|') $t3UpdCurrent
Remove-Item -LiteralPath $t3UpdCurrent -Force
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $t3UpdLegacy))
[IO.File]::WriteAllText($t3UpdLegacy, '{}')
& $t3AllowEveryoneWrite $t3UpdLegacy
Check 'Test-TrustedLegacyMarker: file anyone can write is not trusted' (Test-TrustedLegacyMarker -Path $t3UpdLegacy) 'False'
Check 'Find-ChangeMarkers: untrusted legacy marker is ignored' (@(Find-ChangeMarkers -WorkRoot $t3Wr -UpdaterPaths @($t3UpdCurrent, $t3UpdLegacy)).Count) 0
Check 'Test-TrustedLegacyMarker: missing file is not trusted' (Test-TrustedLegacyMarker -Path (Join-Path $t3Upd 'none.marker')) 'False'

Check 'Test-LastFailure: false when absent' (Test-LastFailure -WorkRoot $t3Wr) 'False'
Write-LastFailure -WorkRoot $t3Wr -RunDir $t3Run -Reason 'VBR did not connect'
Check 'Test-LastFailure: true after Write-LastFailure' (Test-LastFailure -WorkRoot $t3Wr) 'True'
$t3Json = [IO.File]::ReadAllText((Join-Path $t3Wr 'last-failure.json')) | ConvertFrom-Json
Check 'Write-LastFailure: RunDir' (Get-CfgValue -Object $t3Json -Name 'RunDir') $t3Run
Check 'Write-LastFailure: Reason' (Get-CfgValue -Object $t3Json -Name 'Reason') 'VBR did not connect'

# Remove-OldRunData
$t3Old = (Get-Date).AddDays(-40)
$t3Ret = New-TestFolder 'ret'
$t3RetLogs = Join-Path $t3Ret 'logs'
$t3RetRuns = Join-Path $t3Ret 'runs'
[void][IO.Directory]::CreateDirectory($t3RetLogs)
foreach ($t3Name in @('VbrStandardise_SRV_20260801-000000-11.log', 'VbrStandardise_SRV_20261012-000000-12.log', 'other.log')) {
    [IO.File]::WriteAllText((Join-Path $t3RetLogs $t3Name), 'x')
}
[IO.File]::SetLastWriteTime((Join-Path $t3RetLogs 'VbrStandardise_SRV_20260801-000000-11.log'), $t3Old)
[IO.File]::SetLastWriteTime((Join-Path $t3RetLogs 'other.log'), $t3Old)
foreach ($t3Name in @('20260801-000000', '20260802-000000', '20261012-000000')) {
    $t3Dir = Join-Path $t3RetRuns $t3Name
    [void][IO.Directory]::CreateDirectory($t3Dir)
    [IO.File]::WriteAllText((Join-Path $t3Dir 'pg_hba.conf.before'), 'x')
    [IO.File]::SetLastWriteTime((Join-Path $t3Dir 'pg_hba.conf.before'), $t3Old)
}
Write-LastFailure -WorkRoot $t3Ret -RunDir (Join-Path $t3RetRuns '20260802-000000') -Reason 'test'
[IO.File]::SetLastWriteTime((Join-Path $t3Ret 'last-failure.json'), $t3Old)
[IO.Directory]::SetLastWriteTime((Join-Path $t3RetRuns '20260801-000000'), $t3Old)
[IO.Directory]::SetLastWriteTime((Join-Path $t3RetRuns '20260802-000000'), $t3Old)
Remove-OldRunData -WorkRoot $t3Ret -RetentionDays 30
Check 'Remove-OldRunData: old transcript removed' (Test-Path -LiteralPath (Join-Path $t3RetLogs 'VbrStandardise_SRV_20260801-000000-11.log')) 'False'
Check 'Remove-OldRunData: new transcript kept' (Test-Path -LiteralPath (Join-Path $t3RetLogs 'VbrStandardise_SRV_20261012-000000-12.log')) 'True'
Check 'Remove-OldRunData: other files in logs kept' (Test-Path -LiteralPath (Join-Path $t3RetLogs 'other.log')) 'True'
Check 'Remove-OldRunData: old run folder removed' (Test-Path -LiteralPath (Join-Path $t3RetRuns '20260801-000000')) 'False'
Check 'Remove-OldRunData: new run folder kept' (Test-Path -LiteralPath (Join-Path $t3RetRuns '20261012-000000')) 'True'
Check 'Remove-OldRunData: run folder named in last-failure.json kept' (Test-Path -LiteralPath (Join-Path $t3RetRuns '20260802-000000')) 'True'
Check 'Remove-OldRunData: last-failure.json kept' (Test-Path -LiteralPath (Join-Path $t3Ret 'last-failure.json')) 'True'
$t3Dir = Join-Path $t3RetRuns '20260803-000000'
[void][IO.Directory]::CreateDirectory($t3Dir)
[IO.Directory]::SetLastWriteTime($t3Dir, $t3Old)
Write-ChangeMarker -WorkRoot $t3Ret -RunDir $t3Dir -PathName 'A' -Stage 'PATH_A_WRITING'
[IO.File]::SetLastWriteTime((Join-Path $t3Ret 'CHANGES-IN-PROGRESS.marker'), $t3Old)
Remove-OldRunData -WorkRoot $t3Ret -RetentionDays 30
Check 'Remove-OldRunData: every run folder kept while a marker exists' (Test-Path -LiteralPath $t3Dir) 'True'
Check 'Remove-OldRunData: marker kept' (Test-Path -LiteralPath (Join-Path $t3Ret 'CHANGES-IN-PROGRESS.marker')) 'True'
[void](Remove-ChangeMarker -WorkRoot $t3Ret)
Remove-OldRunData -WorkRoot $t3Ret -RetentionDays 0
Check 'Remove-OldRunData: RetentionDays 0 deletes nothing' (Test-Path -LiteralPath $t3Dir) 'True'

# Test-SafeWorkRootParent on a real folder (read only)
Check 'Test-SafeWorkRootParent: C:\ProgramData (parent of the default WorkRoot) is safe' (Test-SafeWorkRootParent -Path 'C:\ProgramData') 'True'

# Test-SafeWorkRootParent and Initialize-WorkRoot with an unsafe parent (elevation needed).
# The fixture must be safe before the Everyone rule is added, or the False result could
# come from something else. A plain folder in the %TEMP% chain is not safe on hosts where
# other accounts have Modify on TEMP, so the fixture lives under C:\ProgramData, whose
# chain is checked safe above. Each refusal below is a True-to-False flip on one folder.
if ($t3IsAdmin) {
    $t3Unsafe = Join-Path 'C:\ProgramData' "vbrstd-unsafe-$PID"
    [void]$script:TestFolders.Add($t3Unsafe)
    try {
        if (Test-Path -LiteralPath $t3Unsafe) { Remove-Item -LiteralPath $t3Unsafe -Recurse -Force }
        [void](New-Item -ItemType Directory -Path $t3Unsafe -Force)
        Check 'Test-SafeWorkRootParent: fresh folder under C:\ProgramData is safe before the rule' (Test-SafeWorkRootParent -Path $t3Unsafe) 'True'
        $t3R = Initialize-WorkRoot -Path (Join-Path $t3Unsafe 'okroot')
        Check 'Initialize-WorkRoot: safe parent under C:\ProgramData is accepted' $t3R.Ok 'True'
        $t3Acl = Get-Acl -LiteralPath $t3Unsafe
        $t3Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $t3Unsafe -AclObject $t3Acl
        Check 'Test-SafeWorkRootParent: folder anyone can delete from is unsafe' (Test-SafeWorkRootParent -Path $t3Unsafe) 'False'
        $t3R = Initialize-WorkRoot -Path (Join-Path $t3Unsafe 'root')
        Check 'Initialize-WorkRoot: unsafe parent is refused' $t3R.Ok 'False'
        Check 'Initialize-WorkRoot: unsafe parent refusal names the parent check' ($t3R.Detail -match 'parent folder can be replaced') 'True'
        Check 'Initialize-WorkRoot: nothing is created under an unsafe parent' (Test-Path -LiteralPath (Join-Path $t3Unsafe 'root')) 'False'
    } finally {
        Remove-Item -LiteralPath $t3Unsafe -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Skip 'Test-SafeWorkRootParent and Initialize-WorkRoot unsafe parent tests' 'not elevated'
}

# Initialize-WorkRoot ACL work and the trusted legacy marker (elevation needed).
# The parent check is mocked here: it is tested above under C:\ProgramData, and on
# some machines other accounts have rights on the TEMP folder chain.
if ($t3IsAdmin) {
    & {
        function Test-SafeWorkRootParent { param([string] $Path) return $true }
        $t3Base = New-TestFolder 'wr'
        $t3Root = Join-Path $t3Base 'root'
        $t3R = Initialize-WorkRoot -Path $t3Root
        Check 'Initialize-WorkRoot: new folder is Ok' $t3R.Ok 'True'
        Check 'Initialize-WorkRoot: creates logs' (Test-Path -LiteralPath (Join-Path $t3Root 'logs') -PathType Container) 'True'
        Check 'Initialize-WorkRoot: creates runs' (Test-Path -LiteralPath (Join-Path $t3Root 'runs') -PathType Container) 'True'
        Check 'Initialize-WorkRoot: writes a trusted sentinel' (Test-RegularTrustedFile -Path (Join-Path $t3Root '.vbr-standardise')) 'True'
        $t3Acl = Get-Acl -LiteralPath $t3Root
        $t3Sids = @($t3Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        Check 'Initialize-WorkRoot: ACL is SYSTEM + Administrators only' ($t3Sids -join ',') 'S-1-5-18,S-1-5-32-544'
        Check 'Initialize-WorkRoot: inheritance is off' $t3Acl.AreAccessRulesProtected 'True'
        Check 'Initialize-WorkRoot: owner is Administrators' $t3Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value 'S-1-5-32-544'
        [IO.File]::WriteAllText((Join-Path $t3Root 'logs\VbrStandardise_x.log'), 'x')
        Check 'Initialize-WorkRoot: rerun on its own folder is Ok' (Initialize-WorkRoot -Path $t3Root).Ok 'True'

        $t3Foreign = Join-Path $t3Base 'foreign'
        [void][IO.Directory]::CreateDirectory($t3Foreign)
        [IO.File]::WriteAllText((Join-Path $t3Foreign 'their-data.txt'), 'do not touch')
        $t3Sddl = (Get-Acl -LiteralPath $t3Foreign).Sddl
        $t3R = Initialize-WorkRoot -Path $t3Foreign
        Check 'Initialize-WorkRoot: foreign folder is refused' $t3R.Ok 'False'
        Check 'Initialize-WorkRoot: foreign folder ACL untouched' ((Get-Acl -LiteralPath $t3Foreign).Sddl -eq $t3Sddl) 'True'
        Check 'Initialize-WorkRoot: foreign folder gets no logs folder' (Test-Path -LiteralPath (Join-Path $t3Foreign 'logs')) 'False'

        $t3Forged = Join-Path $t3Base 'forged'
        Check 'New-ProtectedDirectory: fixture created' (New-ProtectedDirectory -Path $t3Forged) 'True'
        [IO.File]::WriteAllText((Join-Path $t3Forged '.vbr-standardise'), 'forged')
        & $t3SetOwnerAdmins (Join-Path $t3Forged '.vbr-standardise')
        Check 'Initialize-WorkRoot: wrong sentinel text is refused' (Initialize-WorkRoot -Path $t3Forged).Ok 'False'

        $t3Empty = Join-Path $t3Base 'empty'
        [void](New-ProtectedDirectory -Path $t3Empty)
        Check 'Initialize-WorkRoot: empty protected folder is Ok' (Initialize-WorkRoot -Path $t3Empty).Ok 'True'

        $t3Target = New-TestFolder 'wrtarget'
        $t3Junction = Join-Path $t3Root 'runs\linked'
        $t3JunctionMade = $false
        try {
            [void](New-Item -ItemType Junction -Path $t3Junction -Target $t3Target -ErrorAction Stop)
            $t3JunctionMade = $true
            $t3R = Initialize-WorkRoot -Path $t3Root
            Check 'Initialize-WorkRoot: junction inside is refused' $t3R.Ok 'False'
            Check 'Initialize-WorkRoot: junction refusal says why' ($t3R.Detail -match 'reparse point') 'True'
        } catch {
            Skip 'Initialize-WorkRoot: junction inside is refused' "could not create a junction: $($_.Exception.Message)"
        } finally {
            if ($t3JunctionMade) { [IO.Directory]::Delete($t3Junction) }
        }

        $t3Marker = Join-Path $t3Root 'CHANGES-IN-PROGRESS.marker'
        [IO.File]::WriteAllText($t3Marker, '{}')
        & $t3SetOwnerAdmins $t3Marker
        Check 'Test-TrustedLegacyMarker: protected marker is trusted' (Test-TrustedLegacyMarker -Path $t3Marker) 'True'
        Check 'Find-ChangeMarkers: trusted legacy marker found' ((@(Find-ChangeMarkers -WorkRoot $t3Wr -UpdaterPaths @($t3UpdCurrent, $t3Marker))) -join '|') $t3Marker
        $t3Link = Join-Path $t3Base 'link'
        $t3LinkMade = $false
        try {
            [void](New-Item -ItemType Junction -Path $t3Link -Target $t3Root -ErrorAction Stop)
            $t3LinkMade = $true
            Check 'Test-TrustedLegacyMarker: marker reached through a junction is not trusted' (Test-TrustedLegacyMarker -Path (Join-Path $t3Link 'CHANGES-IN-PROGRESS.marker')) 'False'
        } catch {
            Skip 'Test-TrustedLegacyMarker: marker reached through a junction is not trusted' "could not create a junction: $($_.Exception.Message)"
        } finally {
            if ($t3LinkMade) { [IO.Directory]::Delete($t3Link) }
        }
        & $t3AllowEveryoneWrite $t3Marker
        Check 'Test-TrustedLegacyMarker: protected marker made writable is not trusted' (Test-TrustedLegacyMarker -Path $t3Marker) 'False'
        Remove-Item -LiteralPath $t3Marker -Force
    }
} else {
    Skip 'Initialize-WorkRoot ACL and trusted legacy marker tests' 'not elevated'
}
# --- Task 4: VBR registry, products and host class ---
$t4Key = "HKCU:\Software\VbrStdTest-$PID"
$t4SetValue = {
    param([string] $Key, [string] $Name, $Value, [string] $Kind = 'String')
    if (-not (Test-Path -LiteralPath $Key)) { [void](New-Item -Path $Key -Force) }
    [void](New-ItemProperty -LiteralPath $Key -Name $Name -Value $Value -PropertyType $Kind -Force)
}
try {
    # Get-VbrInstall
    $t4Vbr = "$t4Key\VBR"
    $t4R = Get-VbrInstall -RootKey $t4Vbr
    Check 'Get-VbrInstall: missing key is not installed' $t4R.Installed 'False'
    Check 'Get-VbrInstall: missing key has no version' $t4R.Version ''
    Check 'Get-VbrInstall: result shape' (@($t4R.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') 'Installed,CorePath,Version'
    $t4Core = New-TestFolder 'core'
    & $t4SetValue $t4Vbr 'CorePath' (Join-Path $t4Core 'missing')
    Check 'Get-VbrInstall: CorePath folder missing is not installed' (Get-VbrInstall -RootKey $t4Vbr).Installed 'False'
    & $t4SetValue $t4Vbr 'CorePath' $t4Core
    $t4R = Get-VbrInstall -RootKey $t4Vbr
    Check 'Get-VbrInstall: CorePath folder present is installed' $t4R.Installed 'True'
    Check 'Get-VbrInstall: CorePath returned' $t4R.CorePath $t4Core
    Check 'Get-VbrInstall: no binaries gives Unknown' $t4R.Version 'Unknown'
    # Two real binaries with different versions stand in for the Veeam files.
    # Expected values are read from the copies: a System32 file reports the
    # version of its .mui resource, which the copy does not have.
    $t4Dll = Join-Path $t4Core 'Packages\VeeamDeploymentDll.dll'
    $t4Exe = Join-Path $t4Core 'Veeam.Backup.Service.exe'
    [void][IO.Directory]::CreateDirectory((Join-Path $t4Core 'Packages'))
    Copy-Item -LiteralPath ([object].Assembly.Location) -Destination $t4Dll
    $t4DllVersion = "$((Get-Item -LiteralPath $t4Dll).VersionInfo.ProductVersion)".Trim()
    Check 'Get-VbrInstall: falls back to VeeamDeploymentDll.dll' (Get-VbrInstall -RootKey $t4Vbr).Version $t4DllVersion
    Copy-Item -LiteralPath ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Destination $t4Exe
    $t4ExeVersion = "$((Get-Item -LiteralPath $t4Exe).VersionInfo.ProductVersion)".Trim()
    Check 'Get-VbrInstall fixture: the two binaries have different versions' ($t4ExeVersion -ne $t4DllVersion) 'True'
    Check 'Get-VbrInstall: prefers Veeam.Backup.Service.exe' (Get-VbrInstall -RootKey $t4Vbr).Version $t4ExeVersion

    # Get-VbrDbConfig: native authentication shape (VBR-PILOT02)
    $t4Pg = "$t4Vbr\DatabaseConfigurations\PostgreSql"
    & $t4SetValue "$t4Vbr\DatabaseConfigurations" 'SqlActiveConfiguration' 'PostgreSql'
    & $t4SetValue $t4Pg 'SqlHostName' '127.0.0.1'
    & $t4SetValue $t4Pg 'SqlHostPort' 5432 'DWord'
    & $t4SetValue $t4Pg 'SqlDatabaseName' 'VeeamBackup'
    & $t4SetValue $t4Pg 'SqlUserName' 'postgres'
    & $t4SetValue $t4Pg 'SqlSecuredPassword' 'AQAAANCMnd8-fake-secret-1'
    & $t4SetValue $t4Pg 'PostgresUserForWindowsAuth' 'postgres'
    & $t4SetValue $t4Vbr 'EntraIdSqlHostName' 'localhost'
    & $t4SetValue $t4Vbr 'EntraIdSqlHostPort' 5432 'DWord'
    & $t4SetValue $t4Vbr 'EntraIdSqlPassword' 'entra-fake-secret-2'
    $t4C = Get-VbrDbConfig -RootKey $t4Vbr
    Check 'Get-VbrDbConfig: result shape' (@($t4C.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') 'RootKey,KeyPath,ActiveConfiguration,HostName,Port,DatabaseName,UserName,PasswordSet,WindowsAuthRole,EntraIdHost,EntraIdPort,EntraIdPasswordSet'
    Check 'Get-VbrDbConfig: RootKey' $t4C.RootKey $t4Vbr
    Check 'Get-VbrDbConfig: KeyPath' $t4C.KeyPath $t4Pg
    Check 'Get-VbrDbConfig: ActiveConfiguration' $t4C.ActiveConfiguration 'PostgreSql'
    Check 'Get-VbrDbConfig: HostName' $t4C.HostName '127.0.0.1'
    Check 'Get-VbrDbConfig: Port value' $t4C.Port 5432
    Check 'Get-VbrDbConfig: Port is an int' ($t4C.Port -is [int]) 'True'
    Check 'Get-VbrDbConfig: DatabaseName' $t4C.DatabaseName 'VeeamBackup'
    Check 'Get-VbrDbConfig: UserName' $t4C.UserName 'postgres'
    Check 'Get-VbrDbConfig: PasswordSet' $t4C.PasswordSet 'True'
    Check 'Get-VbrDbConfig: WindowsAuthRole' $t4C.WindowsAuthRole 'postgres'
    Check 'Get-VbrDbConfig: EntraIdHost' $t4C.EntraIdHost 'localhost'
    Check 'Get-VbrDbConfig: EntraIdPort' $t4C.EntraIdPort 5432
    Check 'Get-VbrDbConfig: EntraIdPasswordSet' $t4C.EntraIdPasswordSet 'True'
    Check 'Get-VbrDbConfig: never returns password data' (@($t4C.PSObject.Properties | Where-Object { "$($_.Value)" -like '*fake-secret*' }).Count) 0
    Check 'Get-RegistryAuthMode: native registry shape' (Get-RegistryAuthMode -UserName $t4C.UserName -PasswordSet $t4C.PasswordSet) 'NATIVE'

    # Get-VbrDbConfig: Windows authentication shape (VBR-PILOT01)
    & $t4SetValue $t4Pg 'SqlUserName' ''
    & $t4SetValue $t4Pg 'SqlSecuredPassword' ''
    Remove-ItemProperty -LiteralPath $t4Vbr -Name 'EntraIdSqlPassword'
    $t4C = Get-VbrDbConfig -RootKey $t4Vbr
    Check 'Get-VbrDbConfig: empty SqlUserName' $t4C.UserName ''
    Check 'Get-VbrDbConfig: empty SqlSecuredPassword is not set' $t4C.PasswordSet 'False'
    Check 'Get-VbrDbConfig: absent EntraIdSqlPassword is not set' $t4C.EntraIdPasswordSet 'False'
    Check 'Get-RegistryAuthMode: Windows registry shape' (Get-RegistryAuthMode -UserName $t4C.UserName -PasswordSet $t4C.PasswordSet) 'WINDOWS'

    # Get-VbrDbConfig: ports
    & $t4SetValue $t4Pg 'SqlHostPort' '5433'
    Check 'Get-VbrDbConfig: string port is parsed' (Get-VbrDbConfig -RootKey $t4Vbr).Port 5433
    & $t4SetValue $t4Pg 'SqlHostPort' 'abc'
    Check 'Get-VbrDbConfig: text port is null' ($null -eq (Get-VbrDbConfig -RootKey $t4Vbr).Port) 'True'
    & $t4SetValue $t4Pg 'SqlHostPort' 70000 'DWord'
    Check 'Get-VbrDbConfig: out-of-range port is null' ($null -eq (Get-VbrDbConfig -RootKey $t4Vbr).Port) 'True'
    Remove-ItemProperty -LiteralPath $t4Pg -Name 'SqlHostPort'
    Check 'Get-VbrDbConfig: absent port is null' ($null -eq (Get-VbrDbConfig -RootKey $t4Vbr).Port) 'True'
    & $t4SetValue $t4Vbr 'EntraIdSqlHostPort' '5433'
    Check 'Get-VbrDbConfig: string EntraIdPort is parsed' (Get-VbrDbConfig -RootKey $t4Vbr).EntraIdPort 5433
    & $t4SetValue $t4Vbr 'EntraIdSqlHostPort' 'abc'
    Check 'Get-VbrDbConfig: text EntraIdPort is null' ($null -eq (Get-VbrDbConfig -RootKey $t4Vbr).EntraIdPort) 'True'
    & $t4SetValue $t4Vbr 'EntraIdSqlHostPort' 70000 'DWord'
    Check 'Get-VbrDbConfig: out-of-range EntraIdPort is null' ($null -eq (Get-VbrDbConfig -RootKey $t4Vbr).EntraIdPort) 'True'
    Remove-ItemProperty -LiteralPath $t4Vbr -Name 'EntraIdSqlHostPort'
    Check 'Get-VbrDbConfig: absent EntraIdPort is null' ($null -eq (Get-VbrDbConfig -RootKey $t4Vbr).EntraIdPort) 'True'
    Remove-ItemProperty -LiteralPath $t4Pg -Name 'PostgresUserForWindowsAuth'
    Check 'Get-VbrDbConfig: absent PostgresUserForWindowsAuth is empty' (Get-VbrDbConfig -RootKey $t4Vbr).WindowsAuthRole ''
    $t4C = Get-VbrDbConfig -RootKey "$t4Key\NoSuchProduct"
    Check 'Get-VbrDbConfig: missing key gives empty ActiveConfiguration' $t4C.ActiveConfiguration ''
    Check 'Get-VbrDbConfig: missing key gives no password' $t4C.PasswordSet 'False'

    # Get-EnterpriseManagerDbConfig
    $t4Em = "$t4Key\EM"
    Check 'Get-EnterpriseManagerDbConfig: absent key gives null' ($null -eq (Get-EnterpriseManagerDbConfig -RootKey $t4Em)) 'True'
    & $t4SetValue "$t4Em\DatabaseConfigurations" 'SqlActiveConfiguration' 'PostgreSql'
    & $t4SetValue "$t4Em\DatabaseConfigurations\PostgreSql" 'SqlHostName' 'localhost'
    & $t4SetValue "$t4Em\DatabaseConfigurations\PostgreSql" 'SqlHostPort' 5432 'DWord'
    & $t4SetValue "$t4Em\DatabaseConfigurations\PostgreSql" 'SqlSecuredPassword' 'em-fake-secret-3'
    $t4E = Get-EnterpriseManagerDbConfig -RootKey $t4Em
    Check 'Get-EnterpriseManagerDbConfig: result shape' (@($t4E.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') 'ActiveConfiguration,HostName,Port,PasswordSet'
    Check 'Get-EnterpriseManagerDbConfig: ActiveConfiguration' $t4E.ActiveConfiguration 'PostgreSql'
    Check 'Get-EnterpriseManagerDbConfig: HostName' $t4E.HostName 'localhost'
    Check 'Get-EnterpriseManagerDbConfig: Port' $t4E.Port 5432
    Check 'Get-EnterpriseManagerDbConfig: PasswordSet' $t4E.PasswordSet 'True'
    Check 'Get-EnterpriseManagerDbConfig: never returns password data' (@($t4E.PSObject.Properties | Where-Object { "$($_.Value)" -like '*fake-secret*' }).Count) 0

    # Get-EnterpriseManagerDbConfig: ports (same rule as the VBR ports)
    $t4EmPg = "$t4Em\DatabaseConfigurations\PostgreSql"
    & $t4SetValue $t4EmPg 'SqlHostPort' '5433'
    Check 'Get-EnterpriseManagerDbConfig: string port is parsed' (Get-EnterpriseManagerDbConfig -RootKey $t4Em).Port 5433
    & $t4SetValue $t4EmPg 'SqlHostPort' 'abc'
    Check 'Get-EnterpriseManagerDbConfig: text port is null' ($null -eq (Get-EnterpriseManagerDbConfig -RootKey $t4Em).Port) 'True'
    & $t4SetValue $t4EmPg 'SqlHostPort' 70000 'DWord'
    Check 'Get-EnterpriseManagerDbConfig: out-of-range port is null' ($null -eq (Get-EnterpriseManagerDbConfig -RootKey $t4Em).Port) 'True'
    Remove-ItemProperty -LiteralPath $t4EmPg -Name 'SqlHostPort'
    Check 'Get-EnterpriseManagerDbConfig: absent port is null' ($null -eq (Get-EnterpriseManagerDbConfig -RootKey $t4Em).Port) 'True'

    # Get-RegPort: the one port parser behind Port, EntraIdPort and the EM port
    $t4PortKey = "$t4Key\Ports"
    & $t4SetValue $t4PortKey 'P' 5432 'DWord'
    Check 'Get-RegPort: DWord value' (Get-RegPort -Path $t4PortKey -Name 'P') 5432
    Check 'Get-RegPort: result is an int' ((Get-RegPort -Path $t4PortKey -Name 'P') -is [int]) 'True'
    $t4PortCases = @(
        @{ Value = '1'; Expected = '1' }, @{ Value = '65535'; Expected = '65535' }, @{ Value = '5433'; Expected = '5433' },
        @{ Value = '0'; Expected = '' }, @{ Value = '65536'; Expected = '' }, @{ Value = '-1'; Expected = '' },
        @{ Value = ''; Expected = '' }, @{ Value = 'abc'; Expected = '' }, @{ Value = '54x'; Expected = '' }
    )
    foreach ($t4Case in $t4PortCases) {
        & $t4SetValue $t4PortKey 'P' $t4Case.Value
        Check "Get-RegPort: text '$($t4Case.Value)'" "$(Get-RegPort -Path $t4PortKey -Name 'P')" $t4Case.Expected
    }
    Check 'Get-RegPort: absent value is null' ($null -eq (Get-RegPort -Path $t4PortKey -Name 'NoSuchValue')) 'True'
    Check 'Get-RegPort: absent key is null' ($null -eq (Get-RegPort -Path "$t4Key\NoSuchPorts" -Name 'P')) 'True'
} finally {
    if (Test-Path -LiteralPath $t4Key) { Remove-Item -LiteralPath $t4Key -Recurse -Force }
}
Check 'Task 4 registry fixture removed' (Test-Path -LiteralPath $t4Key) 'False'
$t4Defaults = @{}
foreach ($t4Node in $ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (@('Get-VbrInstall', 'Get-VbrDbConfig', 'Get-EnterpriseManagerDbConfig') -notcontains $t4Node.Name) { continue }
    $t4P = @($t4Node.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'RootKey' })
    if ($t4P.Count -eq 1 -and $null -ne $t4P[0].DefaultValue) { $t4Defaults[$t4Node.Name] = $t4P[0].DefaultValue.Extent.Text }
}
Check 'Get-VbrInstall: default root key' $t4Defaults['Get-VbrInstall'] "'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication'"
Check 'Get-VbrDbConfig: default root key' $t4Defaults['Get-VbrDbConfig'] "'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication'"
Check 'Get-EnterpriseManagerDbConfig: default root key' $t4Defaults['Get-EnterpriseManagerDbConfig'] "'HKLM:\SOFTWARE\Veeam\Veeam Backup Reporting'"

# The port rule lives in Get-RegPort only: the readers call it and parse nothing themselves.
$t4Fn = @{}
foreach ($t4Node in $ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $t4Fn[$t4Node.Name] = $t4Node }
$t4FindRegPortCalls = { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-RegPort' }
$t4FindTryParse = { param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and "$($n.Member.Value)" -eq 'TryParse' }
Check 'Get-VbrDbConfig: Port and EntraIdPort call Get-RegPort' (@($t4Fn['Get-VbrDbConfig'].FindAll($t4FindRegPortCalls, $true)).Count) 2
Check 'Get-EnterpriseManagerDbConfig: Port calls Get-RegPort' (@($t4Fn['Get-EnterpriseManagerDbConfig'].FindAll($t4FindRegPortCalls, $true)).Count) 1
Check 'Get-VbrDbConfig: no inline port parser' (@($t4Fn['Get-VbrDbConfig'].FindAll($t4FindTryParse, $true)).Count) 0
Check 'Get-EnterpriseManagerDbConfig: no inline port parser' (@($t4Fn['Get-EnterpriseManagerDbConfig'].FindAll($t4FindTryParse, $true)).Count) 0

# Test-Vb365Installed (service and file lookups mocked)
Check 'Test-Vb365Installed: no service and no file' (& {
    function Get-Service { [CmdletBinding()] param([string[]] $Name) }
    function Test-Path { [CmdletBinding()] param([string[]] $LiteralPath, [string] $PathType) $false }
    Test-Vb365Installed }) 'False'
Check 'Test-Vb365Installed: service present' (& {
    function Get-Service { [CmdletBinding()] param([string[]] $Name) if ($Name -contains 'Veeam.Archiver.Service') { [pscustomobject]@{ Name = 'Veeam.Archiver.Service' } } }
    function Test-Path { [CmdletBinding()] param([string[]] $LiteralPath, [string] $PathType) $false }
    Test-Vb365Installed }) 'True'
Check 'Test-Vb365Installed: executable present' (& {
    function Get-Service { [CmdletBinding()] param([string[]] $Name) }
    function Test-Path { [CmdletBinding()] param([string[]] $LiteralPath, [string] $PathType) ($LiteralPath -contains 'C:\Program Files\Veeam\Backup365\Veeam.Archiver.Service.exe') }
    Test-Vb365Installed }) 'True'

# Get-LocalHostNames
$t4Names = @(Get-LocalHostNames)
Check 'Get-LocalHostNames: includes the computer name' (@($t4Names | Where-Object { $_ -ieq $env:COMPUTERNAME }).Count -ge 1) 'True'
Check 'Get-LocalHostNames: includes 127.0.0.1' ($t4Names -contains '127.0.0.1') 'True'
Check 'Get-LocalHostNames: no empty entries' (@($t4Names | Where-Object { -not $_ }).Count) 0
Check 'Get-LocalHostNames: no duplicates' (@($t4Names | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique).Count) $t4Names.Count

# Get-LocalHostNames: fake adapters. One adapter that fails is skipped and logged;
# the addresses of the adapters before and after it are still listed.
$t4NewNic = {
    param([string] $Name, [string[]] $Addresses, [bool] $Broken = $false)
    $nic = [pscustomobject]@{ Name = $Name; Addresses = $Addresses; Broken = $Broken }
    Add-Member -InputObject $nic -MemberType ScriptMethod -Name GetIPProperties -Value {
        if ($this.Broken) { throw 'adapter went away' }
        [pscustomobject]@{ UnicastAddresses = @($this.Addresses | ForEach-Object { [pscustomobject]@{ Address = [System.Net.IPAddress]::Parse($_) } }) }
    }
    return $nic
}
[void]$script:LogLines.Clear()
$t4NicNames = @(& {
    function Get-LocalNetworkInterfaces {
        (& $t4NewNic 'Ethernet' @('10.77.88.1') $false)
        (& $t4NewNic 'Broken NIC' @() $true)
        (& $t4NewNic 'Ethernet 2' @('10.77.88.99', 'fe80::77%5') $false)
    }
    Get-LocalHostNames
})
Check 'Get-LocalHostNames: address of the adapter before a failing one is listed' ($t4NicNames -contains '10.77.88.1') 'True'
Check 'Get-LocalHostNames: address of the adapter after a failing one is listed' ($t4NicNames -contains '10.77.88.99') 'True'
Check 'Get-LocalHostNames: link-local address of a later adapter is listed without its scope id' ($t4NicNames -contains 'fe80::77') 'True'
Check 'Get-LocalHostNames: failing adapter is logged as WARN with its name and the reason' (@($script:LogLines | Where-Object { $_ -match "^\[WARN\] .*'Broken NIC'.*adapter went away" }).Count) 1
Check 'Get-LocalHostNames: only the failing adapter is logged' (@($script:LogLines | Where-Object { $_ -match "^\[WARN\] .*network adapter" }).Count) 1
[void]$script:LogLines.Clear()
$t4NoNicNames = @(& {
    function Get-LocalNetworkInterfaces { throw 'no network stack' }
    Get-LocalHostNames
})
Check 'Get-LocalHostNames: failed adapter listing still returns the computer name' (@($t4NoNicNames | Where-Object { $_ -ieq $env:COMPUTERNAME }).Count -ge 1) 'True'
Check 'Get-LocalHostNames: failed adapter listing is logged as WARN' (@($script:LogLines | Where-Object { $_ -match "^\[WARN\] .*network adapters.*no network stack" }).Count) 1
# The IPGlobalProperties call cannot be faked, so the catch clauses are checked in the syntax tree:
# only the DNS catch is quiet (a missing DNS record is normal), the other three log a WARN.
$t4Catches = @($t4Fn['Get-LocalHostNames'].FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
Check 'Get-LocalHostNames: catch clause count' $t4Catches.Count 4
$t4Quiet = @($t4Catches | Where-Object { $_.Body.Statements.Count -eq 0 })
Check 'Get-LocalHostNames: exactly one catch is quiet' $t4Quiet.Count 1
Check 'Get-LocalHostNames: the quiet catch is the DNS one' ($t4Quiet.Count -eq 1 -and $t4Quiet[0].Parent.Body.Extent.Text -match 'GetHostEntry') 'True'
Check 'Get-LocalHostNames: every other catch logs a WARN' (@($t4Catches | Where-Object { $_.Body.Statements.Count -gt 0 -and $_.Body.Extent.Text -match "Write-Log\s.*-Level 'WARN'" }).Count) 3

# Get-DbHostClass
$t4Local = @('VBR01', 'vbr01.corp.example', '10.1.2.3', 'fe80::1%12')
Check 'Get-DbHostClass: localhost' (Get-DbHostClass -HostName 'localhost' -LocalNames $t4Local) 'LOOPBACK'
Check 'Get-DbHostClass: LOCALHOST any case' (Get-DbHostClass -HostName 'LOCALHOST' -LocalNames $t4Local) 'LOOPBACK'
Check 'Get-DbHostClass: 127.0.0.1' (Get-DbHostClass -HostName '127.0.0.1' -LocalNames $t4Local) 'LOOPBACK'
Check 'Get-DbHostClass: ::1' (Get-DbHostClass -HostName '::1' -LocalNames $t4Local) 'LOOPBACK'
Check 'Get-DbHostClass: [::1] with brackets' (Get-DbHostClass -HostName '[::1]' -LocalNames $t4Local) 'LOOPBACK'
Check 'Get-DbHostClass: long form of ::1' (Get-DbHostClass -HostName '0:0:0:0:0:0:0:1' -LocalNames $t4Local) 'LOOPBACK'
Check 'Get-DbHostClass: spaces trimmed' (Get-DbHostClass -HostName ' localhost ' -LocalNames $t4Local) 'LOOPBACK'
Check 'Get-DbHostClass: computer name any case' (Get-DbHostClass -HostName 'vbr01' -LocalNames $t4Local) 'LOCAL'
Check 'Get-DbHostClass: FQDN with trailing dot' (Get-DbHostClass -HostName 'VBR01.corp.example.' -LocalNames $t4Local) 'LOCAL'
Check 'Get-DbHostClass: own IP address' (Get-DbHostClass -HostName '10.1.2.3' -LocalNames $t4Local) 'LOCAL'
Check 'Get-DbHostClass: other server' (Get-DbHostClass -HostName 'sql02.corp.example' -LocalNames $t4Local) 'REMOTE'
Check 'Get-DbHostClass: other IP address' (Get-DbHostClass -HostName '10.1.2.4' -LocalNames $t4Local) 'REMOTE'
Check 'Get-DbHostClass: empty host is not proven local' (Get-DbHostClass -HostName '' -LocalNames $t4Local) 'REMOTE'
Check 'Get-DbHostClass: no local names' (Get-DbHostClass -HostName 'vbr01' -LocalNames @()) 'REMOTE'

# Get-RegistryAuthMode
Check 'Get-RegistryAuthMode: empty user, no password' (Get-RegistryAuthMode -UserName '' -PasswordSet $false) 'WINDOWS'
Check 'Get-RegistryAuthMode: null user, no password' (Get-RegistryAuthMode -UserName $null -PasswordSet $false) 'WINDOWS'
Check 'Get-RegistryAuthMode: user and password' (Get-RegistryAuthMode -UserName 'postgres' -PasswordSet $true) 'NATIVE'
Check 'Get-RegistryAuthMode: user only' (Get-RegistryAuthMode -UserName 'postgres' -PasswordSet $false) 'NATIVE'
Check 'Get-RegistryAuthMode: password only' (Get-RegistryAuthMode -UserName '' -PasswordSet $true) 'NATIVE'
# --- Task 5: PostgreSQL discovery ---
# Service binary check (copied from the updater, same cases as its Test-Helpers.ps1).
$t5Base = 'C:\Program Files\PostgreSQL\17'
Check 'T5 quoted pg_ctl service matches BaseDir' (Test-PgServiceExecutableMatchesBaseDir -PathName '"C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe" runservice -N postgresql-x64-17' -BaseDir $t5Base) 'True'
Check 'T5 unquoted pg_ctl service matches BaseDir' (Test-PgServiceExecutableMatchesBaseDir -PathName 'C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe runservice' -BaseDir $t5Base) 'True'
Check 'T5 postgres.exe service binary matches BaseDir' (Test-PgServiceExecutableMatchesBaseDir -PathName '"C:\Program Files\PostgreSQL\17\bin\postgres.exe" -D data' -BaseDir $t5Base) 'True'
Check 'T5 BaseDir with a trailing backslash matches' (Test-PgServiceExecutableMatchesBaseDir -PathName '"C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe" runservice' -BaseDir 'C:\Program Files\PostgreSQL\17\') 'True'
Check 'T5 other major service binary rejected' (Test-PgServiceExecutableMatchesBaseDir -PathName '"C:\Program Files\PostgreSQL\16\bin\pg_ctl.exe" runservice' -BaseDir $t5Base) 'False'
Check 'T5 wrapper service binary rejected' (Test-PgServiceExecutableMatchesBaseDir -PathName '"C:\Vendor\wrapper.exe" run' -BaseDir $t5Base) 'False'

# postmaster.pid as PostgreSQL writes it on Windows: PID, data directory (forward
# slashes), start time (epoch), port, socket directory (empty on Windows), first
# listen address, shared memory key, status.
$t5PidText = "6164`nC:/Program Files/PostgreSQL/15/data`n1728701532`n5432`n`nlocalhost`n  5432001         0`nready   `n"
$t5Pm = ConvertFrom-PostmasterPid -Text $t5PidText
Check 'T5 postmaster.pid PID (line 1)' $t5Pm.Pid '6164'
Check 'T5 postmaster.pid data directory (line 2)' $t5Pm.DataDir 'C:/Program Files/PostgreSQL/15/data'
Check 'T5 postmaster.pid port (line 4)' $t5Pm.Port '5432'
$t5PmCrlf = ConvertFrom-PostmasterPid -Text ($t5PidText -replace "`n", "`r`n")
Check 'T5 postmaster.pid with CRLF: data directory has no CR' $t5PmCrlf.DataDir 'C:/Program Files/PostgreSQL/15/data'
Check 'T5 postmaster.pid with CRLF: port' $t5PmCrlf.Port '5432'
Throws 'T5 postmaster.pid with fewer than 4 lines throws' { ConvertFrom-PostmasterPid -Text "6164`nC:/PG/data" }
Throws 'T5 postmaster.pid with a bad PID throws' { ConvertFrom-PostmasterPid -Text "abc`nC:/PG/data`n1728701532`n5432`n" }
Throws 'T5 postmaster.pid with a bad port throws' { ConvertFrom-PostmasterPid -Text "6164`nC:/PG/data`n1728701532`n`n" }

# Test-PostmasterLive: a temp data folder holds the postmaster.pid; Get-Process is mocked.
$t5Data = New-TestFolder 'pgdata'
$t5DataFwd = $t5Data -replace '\\', '/'
[IO.File]::WriteAllText((Join-Path $t5Data 'postmaster.pid'), "6164`n$t5DataFwd`n1728701532`n5432`n`nlocalhost`n  5432001         0`nready   `n")
& {
    function Get-Process { [CmdletBinding()] param([int] $Id) if ($Id -eq 6164) { [pscustomobject]@{ Id = 6164; ProcessName = 'postgres' } } }
    $t5R = Test-PostmasterLive -DataDir $t5Data -ExpectedPort 5432
    Check 'T5 live postmaster with matching port accepted' $t5R.Ok 'True'
    Check 'T5 data folder with a trailing backslash accepted' (Test-PostmasterLive -DataDir ($t5Data + '\') -ExpectedPort 5432).Ok 'True'
    $t5R = Test-PostmasterLive -DataDir $t5Data -ExpectedPort 5433
    Check 'T5 port different from SqlHostPort rejected' $t5R.Ok 'False'
    Check 'T5 port mismatch detail names both ports' ($t5R.Detail -like '*5432*' -and $t5R.Detail -like '*5433*') 'True'
}
& {
    function Get-Process { [CmdletBinding()] param([int] $Id) [pscustomobject]@{ Id = $Id; ProcessName = 'notepad' } }
    Check 'T5 PID that is not postgres.exe rejected' (Test-PostmasterLive -DataDir $t5Data -ExpectedPort 5432).Ok 'False'
}
& {
    function Get-Process { [CmdletBinding()] param([int] $Id) }
    $t5R = Test-PostmasterLive -DataDir $t5Data -ExpectedPort 5432
    Check 'T5 stale PID rejected' $t5R.Ok 'False'
    Check 'T5 stale PID detail names the PID' ($t5R.Detail -like '*6164*') 'True'
}
[IO.File]::WriteAllText((Join-Path $t5Data 'postmaster.pid'), "$PID`n$t5DataFwd`n1728701532`n5432`n`nlocalhost`n`nready   `n")
Check 'T5 real running process that is not postgres.exe rejected' (Test-PostmasterLive -DataDir $t5Data -ExpectedPort 5432).Ok 'False'
$t5Other = New-TestFolder 'pgother'
[IO.File]::WriteAllText((Join-Path $t5Other 'postmaster.pid'), "6164`nD:/Elsewhere/data`n1728701532`n5432`n`nlocalhost`n`nready   `n")
& {
    function Get-Process { [CmdletBinding()] param([int] $Id) [pscustomobject]@{ Id = $Id; ProcessName = 'postgres' } }
    Check 'T5 postmaster.pid naming another data directory rejected' (Test-PostmasterLive -DataDir $t5Other -ExpectedPort 5432).Ok 'False'
}
$t5Empty = New-TestFolder 'pgempty'
Check 'T5 missing postmaster.pid rejected' (Test-PostmasterLive -DataDir $t5Empty -ExpectedPort 5432).Ok 'False'
[IO.File]::WriteAllText((Join-Path $t5Empty 'postmaster.pid'), 'garbage')
Check 'T5 malformed postmaster.pid rejected' (Test-PostmasterLive -DataDir $t5Empty -ExpectedPort 5432).Ok 'False'

# Get-PgConfSetting: postgresql.conf syntax.
$t5Conf = @(
    "# hba_file = 'ConfigDir/pg_hba.conf'`t`t# host-based authentication file",
    "listen_addresses = 'localhost'`t`t# what IP address(es) to listen on;",
    "port = 5432`t`t`t`t# (change requires restart)",
    '',
    "  HBA_FILE='C:/PG/conf/first.conf'  # moved",
    "hba_file = 'C:/PG/conf/it''s.conf'",
    'shared_buffers 512MB',
    "log_line_prefix = '%m [%p] # kept '"
)
Check 'T5 conf setting: unquoted value' (Get-PgConfSetting -Lines $t5Conf -Name 'port') '5432'
Check 'T5 conf setting: quotes removed' (Get-PgConfSetting -Lines $t5Conf -Name 'listen_addresses') 'localhost'
Check 'T5 conf setting: last active line wins, doubled quote unescaped' (Get-PgConfSetting -Lines $t5Conf -Name 'hba_file') "C:/PG/conf/it's.conf"
Check 'T5 conf setting: name and value without an equals sign' (Get-PgConfSetting -Lines $t5Conf -Name 'shared_buffers') '512MB'
Check 'T5 conf setting: # inside quotes is kept' (Get-PgConfSetting -Lines $t5Conf -Name 'log_line_prefix') '%m [%p] # kept '
Check 'T5 conf setting: absent setting is null' ($null -eq (Get-PgConfSetting -Lines $t5Conf -Name 'ident_file')) 'True'
Check 'T5 conf setting: commented-out setting is null' ($null -eq (Get-PgConfSetting -Lines @("#ident_file = 'C:/x'") -Name 'ident_file')) 'True'
Check 'T5 conf setting: empty file is null' ($null -eq (Get-PgConfSetting -Lines @() -Name 'port')) 'True'

# Test-PgConfOverride: real files in temp folders.
$t5Cfg = New-TestFolder 'pgconf'
[IO.File]::WriteAllText((Join-Path $t5Cfg 'postgresql.conf'), "#hba_file = 'ConfigDir/pg_hba.conf'`r`n#ident_file = 'ConfigDir/pg_ident.conf'`r`nport = 5432`r`n#include_dir = 'conf.d'`r`n")
[IO.File]::WriteAllText((Join-Path $t5Cfg 'postgresql.auto.conf'), "# Do not edit this file manually!`n# It will be overwritten by the ALTER SYSTEM command.`nmax_connections = '200'`n")
Check 'T5 no override in default conf files' (@(Test-PgConfOverride -DataDir $t5Cfg) -join ',') ''
[IO.File]::AppendAllText((Join-Path $t5Cfg 'postgresql.conf'), "hba_file = 'D:/pgconf/pg_hba.conf'`r`n")
Check 'T5 hba_file set in postgresql.conf found' (@(Test-PgConfOverride -DataDir $t5Cfg) -join ',') 'hba_file'
[IO.File]::AppendAllText((Join-Path $t5Cfg 'postgresql.auto.conf'), "ident_file = 'D:/pgconf/pg_ident.conf'`n")
Check 'T5 ident_file set in postgresql.auto.conf found' (@(Test-PgConfOverride -DataDir $t5Cfg) -join ',') 'hba_file,ident_file'
$t5Bom = New-TestFolder 'pgbom'
[IO.File]::WriteAllBytes((Join-Path $t5Bom 'postgresql.conf'), [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::ASCII.GetBytes("ident_file = 'D:/x/pg_ident.conf'`n")))
Check 'T5 override on the first line after a BOM found' (@(Test-PgConfOverride -DataDir $t5Bom) -join ',') 'ident_file'
$t5Inc = New-TestFolder 'pginc'
New-Item -ItemType Directory -Path (Join-Path $t5Inc 'conf.d') | Out-Null
[IO.File]::WriteAllText((Join-Path $t5Inc 'postgresql.conf'), "include_dir = 'conf.d'`ninclude_if_exists = 'missing.conf'`ninclude 'extra.conf'`n")
[IO.File]::WriteAllText((Join-Path $t5Inc 'conf.d\10-tuning.conf'), "work_mem = '8MB'`n")
[IO.File]::WriteAllText((Join-Path $t5Inc 'conf.d\.hidden.conf'), "hba_file = 'D:/x/hidden.conf'`n")
[IO.File]::WriteAllText((Join-Path $t5Inc 'conf.d\readme.txt'), "hba_file = 'D:/x/readme.conf'`n")
[IO.File]::WriteAllText((Join-Path $t5Inc 'extra.conf'), "port = 5432`n")
Check 'T5 included files without overrides' (@(Test-PgConfOverride -DataDir $t5Inc) -join ',') ''
[IO.File]::WriteAllText((Join-Path $t5Inc 'conf.d\20-paths.conf'), "ident_file = 'D:/x/pg_ident.conf'`n")
Check 'T5 override inside include_dir found' (@(Test-PgConfOverride -DataDir $t5Inc) -join ',') 'ident_file'
[IO.File]::WriteAllText((Join-Path $t5Inc 'extra.conf'), "hba_file = 'D:/x/pg_hba.conf'`n")
Check 'T5 override inside an include file found' (@(Test-PgConfOverride -DataDir $t5Inc) -join ',') 'hba_file,ident_file'
$t5Loop = New-TestFolder 'pgloop'
[IO.File]::WriteAllText((Join-Path $t5Loop 'postgresql.conf'), "include 'a.conf'`n")
[IO.File]::WriteAllText((Join-Path $t5Loop 'a.conf'), "include 'postgresql.conf'`n")
Check 'T5 include loop ends' (@(Test-PgConfOverride -DataDir $t5Loop) -join ',') ''
$t5NoConf = New-TestFolder 'pgnoconf'
Check 'T5 missing postgresql.conf counts as both overridden' (@(Test-PgConfOverride -DataDir $t5NoConf) -join ',') 'hba_file,ident_file'
$t5BadInc = New-TestFolder 'pgbadinc'
[IO.File]::WriteAllText((Join-Path $t5BadInc 'postgresql.conf'), "include 'gone.conf'`n")
Check 'T5 missing include file counts as both overridden' (@(Test-PgConfOverride -DataDir $t5BadInc) -join ',') 'hba_file,ident_file'

# Select-ListeningLoopback: pure selection over listener objects.
$t5L = @(
    [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 5432 },
    [pscustomobject]@{ LocalAddress = '::1'; LocalPort = 5432 },
    [pscustomobject]@{ LocalAddress = '192.168.10.5'; LocalPort = 5432 },
    [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 9392 }
)
Check 'T5 both loopback listeners' (@(Select-ListeningLoopback -Listeners $t5L -Port 5432) -join ',') '127.0.0.1,::1'
Check 'T5 listeners on another port ignored' (@(Select-ListeningLoopback -Listeners $t5L -Port 5433) -join ',') ''
Check 'T5 only ::1 listens' (@(Select-ListeningLoopback -Listeners @([pscustomobject]@{ LocalAddress = '::1'; LocalPort = 5432 }) -Port 5432) -join ',') '::1'
Check 'T5 0.0.0.0 counts as 127.0.0.1' (@(Select-ListeningLoopback -Listeners @([pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 5432 }) -Port 5432) -join ',') '127.0.0.1'
Check 'T5 :: counts as ::1' (@(Select-ListeningLoopback -Listeners @([pscustomobject]@{ LocalAddress = '::'; LocalPort = 5432 }) -Port 5432) -join ',') '::1'
Check 'T5 wildcard and loopback listed once' (@(Select-ListeningLoopback -Listeners @([pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 5432 }, [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 5432 }) -Port 5432) -join ',') '127.0.0.1'
Check 'T5 LAN-only listener gives nothing' (@(Select-ListeningLoopback -Listeners @([pscustomobject]@{ LocalAddress = '192.168.10.5'; LocalPort = 5432 }) -Port 5432) -join ',') ''
Check 'T5 no listeners gives nothing' (@(Select-ListeningLoopback -Listeners @() -Port 5432) -join ',') ''

# Get-ListeningLoopback: mocked Get-NetTCPConnection, then one real loopback listener.
& {
    function Get-NetTCPConnection {
        [CmdletBinding()] param([string] $State, [int] $LocalPort)
        if ($State -eq 'Listen') { @([pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = $LocalPort }) }
    }
    Check 'T5 Get-ListeningLoopback asks for listeners on the port' (@(Get-ListeningLoopback -Port 5432) -join ',') '127.0.0.1'
}
& {
    function Get-NetTCPConnection { [CmdletBinding()] param([string] $State, [int] $LocalPort) throw 'CIM query failed' }
    Check 'T5 Get-ListeningLoopback returns nothing when the query fails' (@(Get-ListeningLoopback -Port 5432).Count) '0'
}
$t5Listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$t5Listener.Start()
try {
    $t5Port = ([System.Net.IPEndPoint]$t5Listener.LocalEndpoint).Port
    Check 'T5 real 127.0.0.1 listener found' (@(Get-ListeningLoopback -Port $t5Port) -contains '127.0.0.1') 'True'
} finally {
    $t5Listener.Stop()
}

# Find-PgInstall: a throwaway HKCU installations key and fake service objects.
$t5Root = "HKCU:\Software\VbrStdTest-PgInstall-$PID"
$t5Pg = New-TestFolder 'pgbase'
New-Item -ItemType Directory -Path (Join-Path $t5Pg 'bin') | Out-Null
[IO.File]::WriteAllText((Join-Path $t5Pg 'bin\psql.exe'), '')
$t5PgData = Join-Path $t5Pg 'data'
$t5SvcPg = [pscustomobject]@{ Name = 'postgresql-x64-15'; State = 'Running'; PathName = "`"$t5Pg\bin\pg_ctl.exe`" runservice -N `"postgresql-x64-15`" -D `"$t5PgData`" -w" }
$t5SvcVeeam = [pscustomobject]@{ Name = 'VeeamBackupSvc'; State = 'Running'; PathName = '"C:\Program Files\Veeam\Backup and Replication\Backup\Veeam.Backup.Service.exe"' }
$t5SvcNoPath = [pscustomobject]@{ Name = 'Spooler'; State = 'Running' }
try {
    $t5R = Find-PgInstall -InstallationsKey "$t5Root-absent" -Services @($t5SvcPg)
    Check 'T5 no installations key gives NO_PG_FOUND' $t5R.Code 'NO_PG_FOUND'
    Check 'T5 no installations key is not Ok' $t5R.Ok 'False'
    New-Item -Path $t5Root -Force | Out-Null
    Check 'T5 empty installations key gives NO_PG_FOUND' (Find-PgInstall -InstallationsKey $t5Root -Services @($t5SvcPg)).Code 'NO_PG_FOUND'

    $t5Inst = Join-Path $t5Root 'postgresql-x64-15'
    New-Item -Path $t5Inst -Force | Out-Null
    New-ItemProperty -Path $t5Inst -Name 'Version' -Value '15.8' -PropertyType String | Out-Null
    New-ItemProperty -Path $t5Inst -Name 'Base Directory' -Value $t5Pg -PropertyType String | Out-Null
    New-ItemProperty -Path $t5Inst -Name 'Data Directory' -Value $t5PgData -PropertyType String | Out-Null
    New-ItemProperty -Path $t5Inst -Name 'Service ID' -Value 'postgresql-x64-15' -PropertyType String | Out-Null

    $t5R = Find-PgInstall -InstallationsKey $t5Root -Services @($t5SvcVeeam, $t5SvcNoPath, $t5SvcPg)
    Check 'T5 one install with a running service is Ok' $t5R.Ok 'True'
    Check 'T5 Ok result has no code' $t5R.Code ''
    Check 'T5 version from the registry' $t5R.Version '15.8'
    Check 'T5 major version' $t5R.Major '15'
    Check 'T5 base directory' $t5R.BaseDir $t5Pg
    Check 'T5 data directory' $t5R.DataDir $t5PgData
    Check 'T5 service name' $t5R.ServiceName 'postgresql-x64-15'
    Check 'T5 psql path' $t5R.Psql (Join-Path $t5Pg 'bin\psql.exe')
    Check 'T5 pg_hba.conf path' $t5R.HbaPath (Join-Path $t5PgData 'pg_hba.conf')
    Check 'T5 pg_ident.conf path' $t5R.IdentPath (Join-Path $t5PgData 'pg_ident.conf')

    $t5RealPgServices = @(Get-CimInstance -ClassName Win32_Service | Where-Object { "$($_.Name)" -like 'postgresql*' -or "$($_.PathName)" -match '(?i)(?:^|[\\/"])(?:pg_ctl|postgres)\.exe(?:["\s]|$)' })
    if ($t5RealPgServices.Count -eq 0) {
        $t5R = Find-PgInstall -InstallationsKey $t5Root
        Check 'T5 without -Services the real service list is read' ($t5R.Code -eq 'NO_PG_FOUND' -and $t5R.Detail -like '*no PostgreSQL Windows service*') 'True'
    } else {
        Skip 'T5 without -Services the real service list is read' 'this machine has a PostgreSQL service'
    }

    $t5Stopped = [pscustomobject]@{ Name = 'postgresql-x64-15'; State = 'Stopped'; PathName = $t5SvcPg.PathName }
    $t5R = Find-PgInstall -InstallationsKey $t5Root -Services @($t5Stopped)
    Check 'T5 stopped service gives PG_NOT_RUNNING' $t5R.Code 'PG_NOT_RUNNING'
    Check 'T5 stopped service still names the service' $t5R.ServiceName 'postgresql-x64-15'

    $t5Svc16 = [pscustomobject]@{ Name = 'postgresql-x64-16'; State = 'Running'; PathName = '"C:\Program Files\PostgreSQL\16\bin\pg_ctl.exe" runservice -N "postgresql-x64-16"' }
    Check 'T5 two PostgreSQL services give MULTIPLE_PG' (Find-PgInstall -InstallationsKey $t5Root -Services @($t5SvcPg, $t5Svc16)).Code 'MULTIPLE_PG'
    Check 'T5 no PostgreSQL service gives NO_PG_FOUND' (Find-PgInstall -InstallationsKey $t5Root -Services @($t5SvcVeeam)).Code 'NO_PG_FOUND'

    $t5Elsewhere = [pscustomobject]@{ Name = 'postgresql-x64-15'; State = 'Running'; PathName = '"C:\Program Files\PostgreSQL\16\bin\pg_ctl.exe" runservice -N "postgresql-x64-15"' }
    $t5R = Find-PgInstall -InstallationsKey $t5Root -Services @($t5Elsewhere)
    Check 'T5 service binary outside BaseDir gives NO_PG_FOUND' $t5R.Code 'NO_PG_FOUND'
    Check 'T5 binary mismatch detail names Base Directory' ($t5R.Detail -like '*Base Directory*') 'True'

    $t5Renamed = [pscustomobject]@{ Name = 'postgresql-x64-15b'; State = 'Running'; PathName = $t5SvcPg.PathName }
    $t5R = Find-PgInstall -InstallationsKey $t5Root -Services @($t5Renamed)
    Check 'T5 service name different from Service ID gives NO_PG_FOUND' $t5R.Code 'NO_PG_FOUND'
    Check 'T5 Service ID mismatch detail names both services' ($t5R.Detail -like '*postgresql-x64-15b*' -and $t5R.Detail -like "*'postgresql-x64-15'*") 'True'

    Set-ItemProperty -Path $t5Inst -Name 'Service ID' -Value 'VendorPg'
    $t5Wrapper = [pscustomobject]@{ Name = 'VendorPg'; State = 'Running'; PathName = '"C:\Vendor\wrapper.exe" run' }
    $t5R = Find-PgInstall -InstallationsKey $t5Root -Services @($t5SvcVeeam, $t5Wrapper)
    Check 'T5 service found only through Service ID is checked' $t5R.ServiceName 'VendorPg'
    Check 'T5 wrapper service binary gives NO_PG_FOUND' $t5R.Code 'NO_PG_FOUND'
    Set-ItemProperty -Path $t5Inst -Name 'Service ID' -Value 'postgresql-x64-15'

    Rename-Item -LiteralPath (Join-Path $t5Pg 'bin\psql.exe') -NewName 'psql.exe.away'
    $t5R = Find-PgInstall -InstallationsKey $t5Root -Services @($t5SvcPg)
    Check 'T5 missing psql.exe gives NO_PG_FOUND' $t5R.Code 'NO_PG_FOUND'
    Check 'T5 missing psql.exe detail names psql.exe' ($t5R.Detail -like '*psql.exe*') 'True'
    Rename-Item -LiteralPath (Join-Path $t5Pg 'bin\psql.exe.away') -NewName 'psql.exe'

    Set-ItemProperty -Path $t5Inst -Name 'Version' -Value '17.2-1'
    Check 'T5 installer-style version gives major 17' (Find-PgInstall -InstallationsKey $t5Root -Services @($t5SvcPg)).Major '17'
    Set-ItemProperty -Path $t5Inst -Name 'Version' -Value '15.8'

    Remove-ItemProperty -Path $t5Inst -Name 'Data Directory'
    $t5R = Find-PgInstall -InstallationsKey $t5Root -Services @($t5SvcPg)
    Check 'T5 missing Data Directory gives NO_PG_FOUND' $t5R.Code 'NO_PG_FOUND'
    Check 'T5 missing Data Directory detail names the value' ($t5R.Detail -like '*Data Directory*') 'True'
    New-ItemProperty -Path $t5Inst -Name 'Data Directory' -Value $t5PgData -PropertyType String | Out-Null

    New-Item -Path (Join-Path $t5Root 'postgresql-x64-16') -Force | Out-Null
    Check 'T5 two registered installs give MULTIPLE_PG' (Find-PgInstall -InstallationsKey $t5Root -Services @($t5SvcPg)).Code 'MULTIPLE_PG'
} finally {
    Remove-Item -LiteralPath $t5Root -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\PostgreSQL\Installations')) {
    Check 'T5 default key on a machine without PostgreSQL gives NO_PG_FOUND' (Find-PgInstall).Code 'NO_PG_FOUND'
} else {
    Skip 'T5 default key on a machine without PostgreSQL gives NO_PG_FOUND' 'PostgreSQL is installed on this machine'
}
# --- Task 6: Windows account names for SSPI ---
Check 'T6 map name is name@domain' (ConvertTo-SspiMapName -Domain 'NT AUTHORITY' -Name 'SYSTEM') 'SYSTEM@NT AUTHORITY'
Check 'T6 map name keeps the case it is given' (ConvertTo-SspiMapName -Domain 'Ws-Example' -Name 'svc_veeam') 'svc_veeam@Ws-Example'

# Real SIDs: SYSTEM (S-1-5-18) and the account running the tests.
$t6SystemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
$t6SystemNt = $t6SystemSid.Translate([System.Security.Principal.NTAccount]).Value
if ($t6SystemNt -eq 'NT AUTHORITY\SYSTEM') {
    $t6Parts = Get-NtAccountParts -Sid $t6SystemSid
    Check 'T6 S-1-5-18 domain part' $t6Parts.Domain 'NT AUTHORITY'
    Check 'T6 S-1-5-18 name part' $t6Parts.Name 'SYSTEM'
    Check 'T6 S-1-5-18 map name' (Get-SspiMapNameFromSid -Sid $t6SystemSid) 'SYSTEM@NT AUTHORITY'
} else {
    Skip 'T6 S-1-5-18 domain part' "non-English Windows ($t6SystemNt)"
    Skip 'T6 S-1-5-18 name part' "non-English Windows ($t6SystemNt)"
    Skip 'T6 S-1-5-18 map name' "non-English Windows ($t6SystemNt)"
}
$t6EveryoneSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')
Check 'T6 SID without a domain gives an empty domain part' (Get-NtAccountParts -Sid $t6EveryoneSid).Domain ''
$t6Me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$t6MeDomain = $t6Me.Name.Substring(0, $t6Me.Name.IndexOf('\'))
$t6MeUser = $t6Me.Name.Substring($t6Me.Name.IndexOf('\') + 1)
$t6MeMap = '{0}@{1}' -f $t6MeUser, $t6MeDomain
$t6MeParts = Get-NtAccountParts -Sid $t6Me.User
Check 'T6 current user domain part' $t6MeParts.Domain $t6MeDomain
Check 'T6 current user name part' $t6MeParts.Name $t6MeUser
Check 'T6 current user map name from SID' (Get-SspiMapNameFromSid -Sid $t6Me.User) $t6MeMap

# ASCII test.
Check 'T6 English SYSTEM name is ASCII' (Test-AsciiText -Text 'SYSTEM@NT AUTHORITY') 'True'
Check 'T6 German SYSTEM name is not ASCII' (Test-AsciiText -Text "SYSTEM@NT-AUTORIT$([char]0x00C4)T") 'False'
Check 'T6 tab is not printable ASCII' (Test-AsciiText -Text "SYSTEM`t@NT AUTHORITY") 'False'
Check 'T6 trailing line feed is not printable ASCII' (Test-AsciiText -Text "SYSTEM@NT AUTHORITY`n") 'False'
Check 'T6 empty text is ASCII' (Test-AsciiText -Text '') 'True'

# SYSTEM names: the real translation, then a mocked localised one.
$t6Sys = Get-SystemMapNames
Check 'T6 English SYSTEM name is fixed' $t6Sys.English 'SYSTEM@NT AUTHORITY'
Check 'T6 translated SYSTEM name comes from S-1-5-18' $t6Sys.Translated (Get-SspiMapNameFromSid -Sid $t6SystemSid)
Check 'T6 IsAscii matches the translated name' $t6Sys.IsAscii (Test-AsciiText -Text $t6Sys.Translated)
& {
    function Get-SspiMapNameFromSid { param($Sid) "SYSTEM@NT-AUTORIT$([char]0x00C4)T" }
    $n = Get-SystemMapNames
    Check 'T6 localised SYSTEM name is flagged non-ASCII' $n.IsAscii 'False'
    Check 'T6 localised SYSTEM name is returned' $n.Translated "SYSTEM@NT-AUTORIT$([char]0x00C4)T"
    Check 'T6 English name stays fixed on localised Windows' $n.English 'SYSTEM@NT AUTHORITY'
}

# Resolve-ServiceStartName with a fake translator that records what it was asked.
$t6Seen = New-Object System.Collections.ArrayList
$t6Fake = {
    param([string] $AccountName)
    [void]$t6Seen.Add($AccountName)
    switch -CaseSensitive ($AccountName) {
        'CORP\svc_backup'             { return 'svc_backup@CORP' }
        'CORP\SVC_BACKUP'             { return 'SVC_BACKUP@corp' }
        'svc_backup@corp.example.com' { return 'svc_backup@CORP' }
        'HOST1\localsvc'              { return 'localsvc@HOST1' }
        'CORP\blank'                  { return '' }
        default { throw "Some or all identity references could not be translated: $AccountName" }
    }
}
foreach ($t6Name in @('LocalSystem', 'NT AUTHORITY\SYSTEM', 'nt authority\system', '.\LocalSystem', '')) {
    Check "T6 '$t6Name' is LOCALSYSTEM" (Resolve-ServiceStartName -StartName $t6Name -ComputerName 'HOST1' -Translator $t6Fake).Kind 'LOCALSYSTEM'
}
Check 'T6 null StartName is LOCALSYSTEM' (Resolve-ServiceStartName -StartName $null -ComputerName 'HOST1' -Translator $t6Fake).Kind 'LOCALSYSTEM'
foreach ($t6Name in @('NT AUTHORITY\NetworkService', 'NT AUTHORITY\Network Service', 'NT AUTHORITY\LocalService', 'CORP\gmsa_veeam$')) {
    Check "T6 '$t6Name' is UNSUPPORTED" (Resolve-ServiceStartName -StartName $t6Name -ComputerName 'HOST1' -Translator $t6Fake).Kind 'UNSUPPORTED'
}
Check 'T6 translator not called for LocalSystem or unsupported names' $t6Seen.Count '0'
$t6R = Resolve-ServiceStartName -StartName 'CORP\gmsa_veeam$' -ComputerName 'HOST1' -Translator $t6Fake
Check 'T6 unsupported detail names the account' ($t6R.Detail -like '*CORP\gmsa_veeam$*') 'True'
$t6R = Resolve-ServiceStartName -StartName 'CORP\svc_backup' -ComputerName 'HOST1' -Translator $t6Fake
Check 'T6 DOMAIN\x is ACCOUNT' $t6R.Kind 'ACCOUNT'
Check 'T6 DOMAIN\x map name' $t6R.MapName 'svc_backup@CORP'
$t6R = Resolve-ServiceStartName -StartName 'svc_backup@corp.example.com' -ComputerName 'HOST1' -Translator $t6Fake
Check 'T6 UPN is ACCOUNT' $t6R.Kind 'ACCOUNT'
Check 'T6 UPN map name' $t6R.MapName 'svc_backup@CORP'
$t6Seen.Clear()
$t6R = Resolve-ServiceStartName -StartName '.\localsvc' -ComputerName 'HOST1' -Translator $t6Fake
Check 'T6 .\x is translated as COMPUTERNAME\x' ($t6Seen -join ',') 'HOST1\localsvc'
Check 'T6 .\x map name' $t6R.MapName 'localsvc@HOST1'
$t6R = Resolve-ServiceStartName -StartName 'CORP\gone' -ComputerName 'HOST1' -Translator $t6Fake
Check 'T6 translator error gives UNRESOLVED' $t6R.Kind 'UNRESOLVED'
Check 'T6 UNRESOLVED detail names the account' ($t6R.Detail -like '*CORP\gone*') 'True'
Check 'T6 UNRESOLVED has no map name' ($null -eq $t6R.MapName) 'True'
Check 'T6 empty translation gives UNRESOLVED' (Resolve-ServiceStartName -StartName 'CORP\blank' -ComputerName 'HOST1' -Translator $t6Fake).Kind 'UNRESOLVED'

# Default translator (real LSA lookups).
$t6R = Resolve-ServiceStartName -StartName $t6Me.Name -ComputerName $env:COMPUTERNAME
Check 'T6 default translator resolves the current user' $t6R.Kind 'ACCOUNT'
Check 'T6 default translator map name equals the SID map name' $t6R.MapName $t6MeMap
if ($t6MeDomain -ieq $env:COMPUTERNAME) {
    Check 'T6 default translator resolves .\ for a local account' (Resolve-ServiceStartName -StartName ".\$t6MeUser" -ComputerName $env:COMPUTERNAME).MapName $t6MeMap
} else {
    Skip 'T6 default translator resolves .\ for a local account' 'the test account is not a local account'
}
Check 'T6 default translator: unknown account is UNRESOLVED' (Resolve-ServiceStartName -StartName "NoSuchDomain$PID\nobody$PID" -ComputerName $env:COMPUTERNAME).Kind 'UNRESOLVED'

# Get-VeeamServiceAccountNames over fake services.
$t6Svcs = @(
    [pscustomobject]@{ Name = 'VeeamBackupSvc'; StartName = 'LocalSystem' },
    [pscustomobject]@{ Name = 'VeeamBackupRESTSvc'; StartName = '.\localsvc' },
    [pscustomobject]@{ Name = 'VeeamBrokerSvc'; StartName = 'CORP\svc_backup' },
    [pscustomobject]@{ Name = 'VeeamCatalogSvc'; StartName = 'svc_backup@corp.example.com' },
    [pscustomobject]@{ Name = 'VeeamWebSvc'; StartName = 'CORP\SVC_BACKUP' },
    [pscustomobject]@{ Name = 'VeeamNFSSvc'; StartName = 'NT AUTHORITY\NetworkService' },
    [pscustomobject]@{ Name = 'VeeamCloudSvc'; StartName = 'CORP\gmsa_veeam$' },
    [pscustomobject]@{ Name = 'VeeamMountSvc'; StartName = 'CORP\gone' },
    [pscustomobject]@{ Name = 'VeeamDeploySvc' },
    [pscustomobject]@{ Name = 'Spooler'; StartName = 'CORP\other' }
)
$t6Res = Get-VeeamServiceAccountNames -Services $t6Svcs -ComputerName 'HOST1' -Translator $t6Fake
Check 'T6 service map names: resolved, case-insensitive duplicates removed' (@($t6Res.MapNames) -join ',') 'localsvc@HOST1,svc_backup@CORP'
Check 'T6 unresolved StartNames listed' (@($t6Res.Unresolved) -join ',') 'CORP\gmsa_veeam$,CORP\gone,NT AUTHORITY\NetworkService'
Check 'T6 non-Veeam services ignored' ($t6Seen -contains 'CORP\other') 'False'
Check 'T6 unsupported account logged as WARN with the service name' (@($script:LogLines | Where-Object { $_ -like '`[WARN`]*VeeamCloudSvc*' }).Count -gt 0) 'True'
$t6None = Get-VeeamServiceAccountNames -Services @() -ComputerName 'HOST1' -Translator $t6Fake
Check 'T6 no services: no map names' (@($t6None.MapNames).Count) '0'
Check 'T6 no services: nothing unresolved' (@($t6None.Unresolved).Count) '0'
$t6Default = Get-VeeamServiceAccountNames
Check 'T6 default service list returns both lists' ($null -ne $t6Default.PSObject.Properties['MapNames'] -and $null -ne $t6Default.PSObject.Properties['Unresolved']) 'True'
# --- Task 7: svc_veeam account check and fix ---
Write-Host '--- Task 7: svc_veeam account check and fix ---'

# Exception classes with the LocalAccounts type NAMES. The script maps errors by type name only.
if (-not ('VbrStdT7.InvalidPasswordException' -as [type])) {
    Add-Type -WarningAction SilentlyContinue -TypeDefinition @'
namespace VbrStdT7 {
    public class InvalidPasswordException : System.Exception { public InvalidPasswordException(string m) : base(m) { } }
    public class NameInUseException : System.Exception { public NameInUseException(string m) : base(m) { } }
    public class UserExistsException : System.Exception { public UserExistsException(string m) : base(m) { } }
    public class MemberExistsException : System.Exception { public MemberExistsException(string m) : base(m) { } }
}
'@
}

# A fake Get-ServiceAccountInfo result. The defaults describe a compliant account.
function New-T7Info {
    param(
        [bool] $Exists = $true,
        [bool] $IsUser = $true,
        [int] $UserFlags = 0x10241,
        [bool] $HasExpirationDate = $false,
        [bool] $IsLocked = $false,
        [bool] $PasswordExpired = $false,
        [bool] $IsAdmin = $true
    )
    $sid = $null
    $map = ''
    if ($Exists -and $IsUser) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-21-1111111111-2222222222-3333333333-1001')
        $map = 'svc_veeam@VBR01'
    }
    return [pscustomobject]@{
        Exists = $Exists; IsUser = $IsUser; Sid = $sid; UserFlags = $UserFlags
        HasExpirationDate = $HasExpirationDate; IsLocked = $IsLocked; PasswordExpired = $PasswordExpired
        IsAdmin = $IsAdmin; MapName = $map
    }
}

function New-T7Secure {
    param([string] $Text)
    $secure = New-Object System.Security.SecureString
    foreach ($ch in $Text.ToCharArray()) { $secure.AppendChar($ch) }
    return $secure
}

function New-T7ErrorRecord {
    param([System.Exception] $Exception)
    return (New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList @($Exception, 'T7Test', [System.Management.Automation.ErrorCategory]::NotSpecified, $null))
}

# Every issue as CODE:EXIT; and every issue field as one text (to prove the password never reaches the summary).
function Get-T7Codes { return (@($script:Issues | ForEach-Object { '{0}:{1}' -f $_.Code, $_.ExitCode }) -join ',') }
function Get-T7IssueText { return (@($script:Issues | ForEach-Object { '{0}|{1}|{2}' -f $_.Code, $_.Detail, $_.Action }) -join "`n") }

$t7Secret = "T7-Pw!$PID-q9Z"
$t7EnvName = "VBRSTD_T7_PW_$PID"
$t7SvcSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
$t7Desc = 'Veeam maintenance account (PostgreSQL SSPI map)'
$t7FakeSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-21-1111111111-2222222222-3333333333-4242')

# --- Get-ServiceAccountStatus (pure) ---
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -Exists $false -IsUser $false)
Check 'T7 status: missing account' $t7s.Status 'MISSING'
Check 'T7 status: missing code' ($t7s.Codes -join ',') 'SVC_ACCOUNT_MISSING'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -IsUser $false)
Check 'T7 status: name is a group' $t7s.Status 'NAME_IN_USE'
Check 'T7 status: group code' ($t7s.Codes -join ',') 'SVC_NAME_IN_USE'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info)
Check 'T7 status: compliant account' $t7s.Status 'OK'
Check 'T7 status: compliant has no codes' @($t7s.Codes).Count 0
Check 'T7 status: compliant needs no admin fix' $t7s.NeedsAdmin 'False'
Check 'T7 status: compliant needs no flag fix' $t7s.NeedsFlags 'False'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -IsAdmin $false)
Check 'T7 status: not admin' $t7s.Status 'NOT_ADMIN'
Check 'T7 status: not admin needs admin fix' $t7s.NeedsAdmin 'True'
Check 'T7 status: not admin code' ($t7s.Codes -join ',') 'SVC_NOT_ADMIN'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -UserFlags 0x241)
Check 'T7 status: password expires is drift' $t7s.Status 'FLAGS_DRIFT'
Check 'T7 status: drift needs flag fix' $t7s.NeedsFlags 'True'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -UserFlags 0x10201)
Check 'T7 status: user can change password is drift' $t7s.Status 'FLAGS_DRIFT'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -HasExpirationDate $true)
Check 'T7 status: expiry date present is drift' $t7s.Status 'FLAGS_DRIFT'
Check 'T7 status: expiry date code' ($t7s.Codes -join ',') 'SVC_FLAGS_DRIFT'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -HasExpirationDate $false)
Check 'T7 status: expiry date absent is compliant' $t7s.Status 'OK'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -UserFlags 0x10243)
Check 'T7 status: disabled' $t7s.Status 'DISABLED'
Check 'T7 status: disabled is not flag drift' $t7s.NeedsFlags 'False'
Check 'T7 status: disabled code' ($t7s.Codes -join ',') 'SVC_DISABLED'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -UserFlags 0x10251)
Check 'T7 status: lockout flag 0x10' $t7s.Status 'LOCKED_OUT'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -IsLocked $true)
Check 'T7 status: IsLocked' $t7s.Status 'LOCKED_OUT'
Check 'T7 status: locked code' ($t7s.Codes -join ',') 'SVC_LOCKED_OUT'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -PasswordExpired $true)
Check 'T7 status: password expired' $t7s.Status 'EXPIRED'
Check 'T7 status: expired code' ($t7s.Codes -join ',') 'SVC_PASSWORD_EXPIRED'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -IsAdmin $false -UserFlags 0x13 -HasExpirationDate $true -PasswordExpired $true)
Check 'T7 status: precedence starts with NOT_ADMIN' $t7s.Status 'NOT_ADMIN'
Check 'T7 status: every code in order' ($t7s.Codes -join ',') 'SVC_NOT_ADMIN,SVC_FLAGS_DRIFT,SVC_DISABLED,SVC_LOCKED_OUT,SVC_PASSWORD_EXPIRED'
$t7s = Get-ServiceAccountStatus -Info (New-T7Info -UserFlags 0x10253 -PasswordExpired $true)
Check 'T7 status: DISABLED before LOCKED_OUT and EXPIRED' $t7s.Status 'DISABLED'
$t7s = Get-ServiceAccountStatus -Info ([pscustomobject]@{ Exists = $true; IsUser = $true })
Check 'T7 status: partial object is StrictMode-safe' $t7s.Status 'NOT_ADMIN'

# --- ConvertTo-AccountIssueCode (matched by exception type name) ---
Check 'T7 map: InvalidPasswordException' (ConvertTo-AccountIssueCode -ErrorRecord (New-T7ErrorRecord (New-Object VbrStdT7.InvalidPasswordException('policy')))) 'SVC_PASSWORD_POLICY'
Check 'T7 map: NameInUseException' (ConvertTo-AccountIssueCode -ErrorRecord (New-T7ErrorRecord (New-Object VbrStdT7.NameInUseException('in use')))) 'SVC_NAME_IN_USE'
Check 'T7 map: UserExistsException' (ConvertTo-AccountIssueCode -ErrorRecord (New-T7ErrorRecord (New-Object VbrStdT7.UserExistsException('exists')))) 'SVC_NAME_IN_USE'
$t7Wrapped = New-Object System.Management.Automation.RuntimeException('outer', (New-Object VbrStdT7.InvalidPasswordException('policy')))
Check 'T7 map: wrapped InvalidPasswordException' (ConvertTo-AccountIssueCode -ErrorRecord (New-T7ErrorRecord $t7Wrapped)) 'SVC_PASSWORD_POLICY'
Check 'T7 map: MemberExistsException is not a create code' ($null -eq (ConvertTo-AccountIssueCode -ErrorRecord (New-T7ErrorRecord (New-Object VbrStdT7.MemberExistsException('member'))))) 'True'
Check 'T7 map: other exception gives null' ($null -eq (ConvertTo-AccountIssueCode -ErrorRecord (New-T7ErrorRecord (New-Object System.InvalidOperationException('other'))))) 'True'

# --- Read-ServiceAccountPassword (process environment variable) ---
[System.Environment]::SetEnvironmentVariable($t7EnvName, $t7Secret, 'Process')
$t7Out = @(Read-ServiceAccountPassword -EnvVarName $t7EnvName)
Check 'T7 password: one output object' $t7Out.Count 1
Check 'T7 password: is a SecureString' ($t7Out[0] -is [System.Security.SecureString]) 'True'
Check 'T7 password: right length' $t7Out[0].Length $t7Secret.Length
$t7Bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($t7Out[0])
try { $t7Back = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($t7Bstr) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($t7Bstr) }
Check 'T7 password: same text' ($t7Back -ceq $t7Secret) 'True'
$t7Back = $null
$t7Out[0].Dispose()
Check 'T7 password: variable removed from the process' ($null -eq [System.Environment]::GetEnvironmentVariable($t7EnvName, 'Process')) 'True'
Check 'T7 password: env drive no longer has it' (Test-Path -LiteralPath "env:$t7EnvName") 'False'
Check 'T7 password: missing variable gives null' ($null -eq (Read-ServiceAccountPassword -EnvVarName $t7EnvName)) 'True'
Check 'T7 password: never logged' (($script:LogLines -join "`n").Contains($t7Secret)) 'False'

# --- Get-ServiceAccountInfo and Test-AdministratorsMember (real ADSI reads, no changes) ---
$t7Nope = Get-ServiceAccountInfo -Name ('vbrstd-nope-{0}' -f $PID)
Check 'T7 info: unknown name does not exist' $t7Nope.Exists 'False'
Check 'T7 info: unknown name is not a user' $t7Nope.IsUser 'False'
Check 'T7 info: unknown name is not admin' $t7Nope.IsAdmin 'False'
Check 'T7 info: unknown name has no SID' ($null -eq $t7Nope.Sid) 'True'
Check 'T7 status: unknown name is MISSING' (Get-ServiceAccountStatus -Info $t7Nope).Status 'MISSING'
$t7AdminsName = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
$t7Group = Get-ServiceAccountInfo -Name $t7AdminsName
Check 'T7 info: group name exists' $t7Group.Exists 'True'
Check 'T7 info: group name is not a user' $t7Group.IsUser 'False'
Check 'T7 status: group name is NAME_IN_USE' (Get-ServiceAccountStatus -Info $t7Group).Status 'NAME_IN_USE'
Check 'T7 admins: unknown SID is not a member' (Test-AdministratorsMember -MemberSid $t7FakeSid) 'False'
$t7Rid500 = @(Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True AND SID LIKE 'S-1-5-21-%-500'" -ErrorAction SilentlyContinue)
$t7RidChecks = @('T7 admins: built-in Administrator is a member', 'T7 info: built-in Administrator exists',
    'T7 info: built-in Administrator is a user', 'T7 info: SID read from objectSid', 'T7 info: IsAdmin by SID',
    'T7 info: UserFlags has NORMAL_ACCOUNT', 'T7 info: MapName is name@domain', 'T7 info: HasExpirationDate is a bool')
if ($t7Rid500.Count -eq 1) {
    $t7RidSid = New-Object System.Security.Principal.SecurityIdentifier($t7Rid500[0].SID)
    Check $t7RidChecks[0] (Test-AdministratorsMember -MemberSid $t7RidSid) 'True'
    $t7Real = Get-ServiceAccountInfo -Name $t7Rid500[0].Name
    Check $t7RidChecks[1] $t7Real.Exists 'True'
    Check $t7RidChecks[2] $t7Real.IsUser 'True'
    Check $t7RidChecks[3] $t7Real.Sid.Value $t7RidSid.Value
    Check $t7RidChecks[4] $t7Real.IsAdmin 'True'
    Check $t7RidChecks[5] (($t7Real.UserFlags -band 0x200) -ne 0) 'True'
    Check $t7RidChecks[6] ($t7Real.MapName -like ('{0}@*' -f $t7Rid500[0].Name)) 'True'
    Check $t7RidChecks[7] ($t7Real.HasExpirationDate -is [bool]) 'True'
} else {
    foreach ($t7Name in $t7RidChecks) { Skip $t7Name 'built-in Administrator (RID 500) not found' }
}

# --- Add-AdministratorsMember (Add-LocalGroupMember mocked; the fake SID does not exist) ---
& {
    $t7Seen = New-Object System.Collections.ArrayList
    function Add-LocalGroupMember { [CmdletBinding()] param($SID, $Member) [void]$t7Seen.Add(('{0}>{1}' -f $SID, $Member)) }
    Add-AdministratorsMember -UserSid $t7FakeSid -UserName 'vbrstd-t7'
    Check 'T7 add admin: Administrators by SID, member by SID' ($t7Seen -join ';') ('S-1-5-32-544>' + $t7FakeSid.Value)
}
& {
    function Add-LocalGroupMember { [CmdletBinding()] param($SID, $Member) throw (New-Object VbrStdT7.MemberExistsException('exists')) }
    $t7Threw = $false
    try { Add-AdministratorsMember -UserSid $t7FakeSid -UserName 'vbrstd-t7' } catch { $t7Threw = $true }
    Check 'T7 add admin: MemberExistsException counts as success' $t7Threw 'False'
}
& {
    function Add-LocalGroupMember { [CmdletBinding()] param($SID, $Member) throw (New-Object System.UnauthorizedAccessException('Access is denied.')) }
    Throws 'T7 add admin: other errors are thrown' { Add-AdministratorsMember -UserSid $t7FakeSid -UserName 'vbrstd-t7' }
}

# --- New-ServiceAccount (New-LocalUser mocked) ---
& {
    $t7Seen = @{}
    function New-LocalUser {
        [CmdletBinding()]
        param($Name, $Password, $Description, [switch] $PasswordNeverExpires, [switch] $UserMayNotChangePassword, [switch] $AccountNeverExpires)
        $t7Seen['Name'] = $Name
        $t7Seen['Description'] = $Description
        $t7Seen['PasswordIsSecure'] = ($Password -is [System.Security.SecureString])
        $t7Seen['Switches'] = ('{0},{1},{2}' -f $PasswordNeverExpires.IsPresent, $UserMayNotChangePassword.IsPresent, $AccountNeverExpires.IsPresent)
        return [pscustomobject]@{ Name = $Name }
    }
    $t7Pw = New-T7Secure 'Unused-T7-pw-1'
    $t7R = New-ServiceAccount -Name 'vbrstd-t7' -Password $t7Pw -Description $t7Desc
    Check 'T7 create: Created' $t7R.Created 'True'
    Check 'T7 create: no issue code' $t7R.IssueCode ''
    Check 'T7 create: name passed' $t7Seen['Name'] 'vbrstd-t7'
    Check 'T7 create: description passed' $t7Seen['Description'] $t7Desc
    Check 'T7 create: password passed as SecureString' $t7Seen['PasswordIsSecure'] 'True'
    Check 'T7 create: three flag switches' $t7Seen['Switches'] 'True,True,True'
    $t7R = New-ServiceAccount -Name 'vbrstd-t7' -Password $t7Pw -Description ('x' * 60)
    Check 'T7 create: description cut to 48 characters' $t7Seen['Description'].Length 48
    $t7Pw.Dispose()
}
& {
    function New-LocalUser {
        [CmdletBinding()]
        param($Name, $Password, $Description, [switch] $PasswordNeverExpires, [switch] $UserMayNotChangePassword, [switch] $AccountNeverExpires)
        throw (New-Object VbrStdT7.InvalidPasswordException('The password does not meet the password policy requirements.'))
    }
    $t7Pw = New-T7Secure 'Unused-T7-pw-2'
    $t7R = New-ServiceAccount -Name 'vbrstd-t7' -Password $t7Pw -Description 'd'
    Check 'T7 create: policy failure is not Created' $t7R.Created 'False'
    Check 'T7 create: policy failure code' $t7R.IssueCode 'SVC_PASSWORD_POLICY'
    $t7Pw.Dispose()
}
& {
    function New-LocalUser {
        [CmdletBinding()]
        param($Name, $Password, $Description, [switch] $PasswordNeverExpires, [switch] $UserMayNotChangePassword, [switch] $AccountNeverExpires)
        throw (New-Object VbrStdT7.NameInUseException('The name is already in use.'))
    }
    $t7Pw = New-T7Secure 'Unused-T7-pw-3'
    $t7R = New-ServiceAccount -Name 'vbrstd-t7' -Password $t7Pw -Description 'd'
    Check 'T7 create: name clash is not Created' $t7R.Created 'False'
    Check 'T7 create: name clash code' $t7R.IssueCode 'SVC_NAME_IN_USE'
    $t7Pw.Dispose()
}
& {
    function New-LocalUser {
        [CmdletBinding()]
        param($Name, $Password, $Description, [switch] $PasswordNeverExpires, [switch] $UserMayNotChangePassword, [switch] $AccountNeverExpires)
        throw (New-Object System.UnauthorizedAccessException('Access is denied.'))
    }
    $t7Pw = New-T7Secure 'Unused-T7-pw-4'
    Throws 'T7 create: other errors are thrown' { New-ServiceAccount -Name 'vbrstd-t7' -Password $t7Pw -Description 'd' }
    $t7Pw.Dispose()
}

# --- Set-ServiceAccountFlags (Set-LocalUser mocked) ---
& {
    $t7Seen = @{}
    function Set-LocalUser {
        [CmdletBinding()]
        param($Name, $PasswordNeverExpires, $UserMayChangePassword, [switch] $AccountNeverExpires)
        $t7Seen['Call'] = ('{0}|{1}|{2}|{3}' -f $Name, $PasswordNeverExpires, $UserMayChangePassword, $AccountNeverExpires.IsPresent)
    }
    Set-ServiceAccountFlags -Name 'vbrstd-t7'
    Check 'T7 flags: Set-LocalUser with the three flags' $t7Seen['Call'] 'vbrstd-t7|True|False|True'
}

# --- Invoke-ServiceAccountStep (every system call mocked) ---
# Default state for one scenario. Dot-source it in a child scope, change what the scenario
# needs, then dot-source $t7StepMocks. All names start with t7 so they never collide with
# the local variables of Invoke-ServiceAccountStep (the mocks find them by dynamic scope).
$t7NewScene = {
    $script:Issues = New-Object System.Collections.ArrayList
    $t7Calls = New-Object System.Collections.ArrayList
    $t7Infos = New-Object System.Collections.ArrayList
    $t7Pw = $null
    $t7Create = [pscustomobject]@{ Created = $true; IssueCode = '' }
    $t7AdminError = ''
    $t7FlagsError = ''
}
$t7StepMocks = {
    function Read-ServiceAccountPassword { param([string] $EnvVarName) [void]$t7Calls.Add("read:$EnvVarName"); return $t7Pw }
    function Get-ServiceAccountInfo {
        param([string] $Name)
        [void]$t7Calls.Add("info:$Name")
        $next = $t7Infos[0]
        if ($t7Infos.Count -gt 1) { $t7Infos.RemoveAt(0) }
        return $next
    }
    function New-ServiceAccount { param([string] $Name, $Password, [string] $Description) [void]$t7Calls.Add("create:$Name|$Description"); return $t7Create }
    function Add-AdministratorsMember { param($UserSid, [string] $UserName) [void]$t7Calls.Add("admin:$UserSid|$UserName"); if ($t7AdminError) { throw $t7AdminError } }
    function Set-ServiceAccountFlags { param([string] $Name) [void]$t7Calls.Add("flags:$Name"); if ($t7FlagsError) { throw $t7FlagsError } }
}

& {
    . $t7NewScene
    [void]$t7Infos.Add((New-T7Info -Exists $false -IsUser $false))
    . $t7StepMocks
    $t7R = Invoke-ServiceAccountStep -Config (Get-DefaultConfig) -Apply $false -CreateRequested $false
    Check 'T7 step audit missing: status MISSING' $t7R.Status 'MISSING'
    Check 'T7 step audit missing: blocks the database change' $t7R.BlocksDb 'True'
    Check 'T7 step audit missing: issue' (Get-T7Codes) 'SVC_ACCOUNT_MISSING:5'
    Check 'T7 step audit missing: action' $script:Issues[0].Action 'Set RMM secure variable VEEAM_SVC_PASSWORD and re-run with -CreateServiceAccount'
    Check 'T7 step audit missing: password variable read once' (@($t7Calls | Where-Object { $_ -eq 'read:VEEAM_SVC_PASSWORD' }).Count) 1
    Check 'T7 step audit missing: no change' (@($t7Calls | Where-Object { $_ -match '^(create|admin|flags):' }) -join ';') ''
}
& {
    . $t7NewScene
    [void]$t7Infos.Add((New-T7Info -Exists $false -IsUser $false))
    $t7Pw = New-T7Secure $t7Secret
    . $t7StepMocks
    $t7R = Invoke-ServiceAccountStep -Config (Get-DefaultConfig) -Apply $true -CreateRequested $false
    Check 'T7 step apply missing: issue' (Get-T7Codes) 'SVC_ACCOUNT_MISSING:5'
    Check 'T7 step apply missing: not created without -CreateServiceAccount' (@($t7Calls | Where-Object { $_ -match '^(create|admin|flags):' }) -join ';') ''
    Check 'T7 step apply missing: blocks the database change' $t7R.BlocksDb 'True'
    Throws 'T7 step apply missing: unused password disposed' { $null = $t7Pw.Copy() }
}
& {
    . $t7NewScene
    [void]$t7Infos.Add((New-T7Info -Exists $false -IsUser $false))
    . $t7StepMocks
    $t7R = Invoke-ServiceAccountStep -Config (Get-DefaultConfig) -Apply $false -CreateRequested $true
    Check 'T7 step create no password: issue' (Get-T7Codes) 'SVC_PASSWORD_REQUIRED:5'
    Check 'T7 step create no password: action' $script:Issues[0].Action 'Set RMM secure variable VEEAM_SVC_PASSWORD and re-run with -CreateServiceAccount'
    Check 'T7 step create no password: nothing created' (@($t7Calls | Where-Object { $_ -match '^(create|admin|flags):' }) -join ';') ''
    Check 'T7 step create no password: status MISSING' $t7R.Status 'MISSING'
    Check 'T7 step create no password: blocks the database change' $t7R.BlocksDb 'True'
}
& {
    . $t7NewScene
    [void]$t7Infos.Add((New-T7Info -Exists $false -IsUser $false))
    $t7Pw = New-T7Secure $t7Secret
    $t7Create = [pscustomobject]@{ Created = $false; IssueCode = 'SVC_PASSWORD_POLICY' }
    . $t7StepMocks
    $t7R = Invoke-ServiceAccountStep -Config (Get-DefaultConfig) -Apply $true -CreateRequested $true
    Check 'T7 step policy: issue' (Get-T7Codes) 'SVC_PASSWORD_POLICY:5'
    Check 'T7 step policy: create called once with name and description' (@($t7Calls | Where-Object { $_ -match '^(create|admin|flags):' }) -join ';') ("create:svc_veeam|$t7Desc")
    Check 'T7 step policy: status MISSING' $t7R.Status 'MISSING'
    Check 'T7 step policy: blocks the database change' $t7R.BlocksDb 'True'
    Throws 'T7 step policy: password disposed after the step' { $null = $t7Pw.Copy() }
    Check 'T7 step policy: password not in the log' (($script:LogLines -join "`n").Contains($t7Secret)) 'False'
    Check 'T7 step policy: password not in the issues' ((Get-T7IssueText).Contains($t7Secret)) 'False'
}
& {
    . $t7NewScene
    [void]$t7Infos.Add((New-T7Info -Exists $false -IsUser $false))
    $t7Pw = New-T7Secure $t7Secret
    $t7Create = [pscustomobject]@{ Created = $false; IssueCode = 'SVC_NAME_IN_USE' }
    . $t7StepMocks
    $t7R = Invoke-ServiceAccountStep -Config (Get-DefaultConfig) -Apply $false -CreateRequested $true
    Check 'T7 step create name clash: issue' (Get-T7Codes) 'SVC_NAME_IN_USE:5'
    Check 'T7 step create name clash: status NAME_IN_USE' $t7R.Status 'NAME_IN_USE'
    Check 'T7 step create name clash: blocks the database change' $t7R.BlocksDb 'True'
}
& {
    . $t7NewScene
    [void]$t7Infos.Add((New-T7Info -Exists $false -IsUser $false))
    [void]$t7Infos.Add((New-T7Info -IsAdmin $false))
    [void]$t7Infos.Add((New-T7Info))
    $t7Pw = New-T7Secure $t7Secret
    . $t7StepMocks
    $t7R = Invoke-ServiceAccountStep -Config (Get-DefaultConfig) -Apply $false -CreateRequested $true
    Check 'T7 step create: created, then added to Administrators by SID' (@($t7Calls | Where-Object { $_ -match '^(create|admin|flags):' }) -join ';') ("create:svc_veeam|$t7Desc;admin:$t7SvcSid|svc_veeam")
    Check 'T7 step create: read back after each change' (@($t7Calls | Where-Object { $_ -eq 'info:svc_veeam' }).Count) 3
    Check 'T7 step create: no issues' (Get-T7Codes) ''
    Check 'T7 step create: status OK' $t7R.Status 'OK'
    Check 'T7 step create: does not block' $t7R.BlocksDb 'False'
    Check 'T7 step create: Info is the last read' $t7R.Info.IsAdmin 'True'
    Throws 'T7 step create: password disposed after the step' { $null = $t7Pw.Copy() }
}
& {
    . $t7NewScene
    [void]$t7Infos.Add((New-T7Info -IsAdmin $false -UserFlags 0x203))
    . $t7StepMocks
    $t7R = Invoke-ServiceAccountStep -Config (Get-DefaultConfig) -Apply $false -CreateRequested $false
    Check 'T7 step audit drift: every issue in order' (Get-T7Codes) 'SVC_NOT_ADMIN:5,SVC_FLAGS_DRIFT:5,SVC_DISABLED:5'
    Check 'T7 step audit drift: status NOT_ADMIN' $t7R.Status 'NOT_ADMIN'
    Check 'T7 step audit drift: blocks the database change' $t7R.BlocksDb 'True'
    Check 'T7 step audit drift: nothing changed' (@($t7Calls | Where-Object { $_ -match '^(create|admin|flags):' }) -join ';') ''
    Check 'T7 step audit drift: read once' (@($t7Calls | Where-Object { $_ -eq 'info:svc_veeam' }).Count) 1
    Check 'T7 step audit drift: detail names the flags' ($script:Issues[1].Detail -like '*the password expires*the user can change the password*') 'True'
    Check 'T7 step audit drift: action asks for -Apply' ($script:Issues[0].Action -like '*-Apply*') 'True'
}
& {
    . $t7NewScene
    [void]$t7Infos.Add((New-T7Info -IsAdmin $false -UserFlags 0x211 -HasExpirationDate $true))
    [void]$t7Infos.Add((New-T7Info -UserFlags 0x10251))
    . $t7StepMocks
    $t7R = Invoke-ServiceAccountStep -Config (Get-DefaultConfig) -Apply $true -CreateRequested $false
    Check 'T7 step apply drift: admin and flags fixed' (@($t7Calls | Where-Object { $_ -match '^(create|admin|flags):' }) -join ';') ("admin:$t7SvcSid|svc_veeam;flags:svc_veeam")
    Check 'T7 step apply drift: read again after the fix' (@($t7Calls | Where-Object { $_ -eq 'info:svc_veeam' }).Count) 2
    Check 'T7 step apply drift: lockout is report-only' (Get-T7Codes) 'SVC_LOCKED_OUT:5'
    Check 'T7 step apply drift: status LOCKED_OUT' $t7R.Status 'LOCKED_OUT'
    Check 'T7 step apply drift: lockout does not block' $t7R.BlocksDb 'False'
}
& {
    . $t7NewScene
    [void]$t7Infos.Add((New-T7Info -IsAdmin $false))
    $t7AdminError = 'Access is denied.'
    . $t7StepMocks
    $t7R = Invoke-ServiceAccountStep -Config (Get-DefaultConfig) -Apply $true -CreateRequested $false
    Check 'T7 step admin add fails: issue' (Get-T7Codes) 'SVC_NOT_ADMIN:5'
    Check 'T7 step admin add fails: detail has the error' ($script:Issues[0].Detail -like '*Access is denied.*') 'True'
    Check 'T7 step admin add fails: blocks the database change' $t7R.BlocksDb 'True'
}
& {
    . $t7NewScene
    [void]$t7Infos.Add((New-T7Info -IsUser $false))
    $t7Pw = New-T7Secure $t7Secret
    . $t7StepMocks
    $t7R = Invoke-ServiceAccountStep -Config (Get-DefaultConfig) -Apply $true -CreateRequested $true
    Check 'T7 step group: issue' (Get-T7Codes) 'SVC_NAME_IN_USE:5'
    Check 'T7 step group: status NAME_IN_USE' $t7R.Status 'NAME_IN_USE'
    Check 'T7 step group: blocks the database change' $t7R.BlocksDb 'True'
    Check 'T7 step group: nothing changed' (@($t7Calls | Where-Object { $_ -match '^(create|admin|flags):' }) -join ';') ''
}
& {
    . $t7NewScene
    [void]$t7Infos.Add((New-T7Info -IsAdmin $false))
    [void]$t7Infos.Add((New-T7Info))
    $t7Pw = New-T7Secure $t7Secret
    . $t7StepMocks
    $t7R = Invoke-ServiceAccountStep -Config (Get-DefaultConfig) -Apply $false -CreateRequested $true
    Check 'T7 step create existing: only added to Administrators (password never reset)' (@($t7Calls | Where-Object { $_ -match '^(create|admin|flags):' }) -join ';') ("admin:$t7SvcSid|svc_veeam")
    Check 'T7 step create existing: no issues' (Get-T7Codes) ''
    Check 'T7 step create existing: does not block' $t7R.BlocksDb 'False'
}
& {
    . $t7NewScene
    [void]$t7Infos.Add((New-T7Info))
    . $t7StepMocks
    $t7R = Invoke-ServiceAccountStep -Config (Get-DefaultConfig) -Apply $false -CreateRequested $false
    Check 'T7 step compliant: status OK' $t7R.Status 'OK'
    Check 'T7 step compliant: no issues' (Get-T7Codes) ''
    Check 'T7 step compliant: does not block' $t7R.BlocksDb 'False'
    Check 'T7 step compliant: read once' (@($t7Calls | Where-Object { $_ -eq 'info:svc_veeam' }).Count) 1
    Check 'T7 step compliant: logs the map name' (@($script:LogLines | Where-Object { $_ -like '*svc_veeam: OK*svc_veeam@VBR01*' }).Count -gt 0) 'True'
}
# Real Read-ServiceAccountPassword and New-ServiceAccount; only New-LocalUser and the account read are mocked.
& {
    $script:Issues = New-Object System.Collections.ArrayList
    $t7Seen = @{ Length = -1 }
    $t7Cfg = (Get-DefaultConfig).Clone()
    $t7Cfg['PasswordEnvVar'] = $t7EnvName
    [System.Environment]::SetEnvironmentVariable($t7EnvName, $t7Secret, 'Process')
    function Get-ServiceAccountInfo { param([string] $Name) return (New-T7Info -Exists $false -IsUser $false) }
    function New-LocalUser {
        [CmdletBinding()]
        param($Name, $Password, $Description, [switch] $PasswordNeverExpires, [switch] $UserMayNotChangePassword, [switch] $AccountNeverExpires)
        $t7Seen['Length'] = $Password.Length
        throw (New-Object VbrStdT7.InvalidPasswordException('The password does not meet the password policy requirements.'))
    }
    function Add-AdministratorsMember { param($UserSid, [string] $UserName) throw 'T7: Add-AdministratorsMember must not be called' }
    function Set-ServiceAccountFlags { param([string] $Name) throw 'T7: Set-ServiceAccountFlags must not be called' }
    $t7R = Invoke-ServiceAccountStep -Config $t7Cfg -Apply $false -CreateRequested $true
    Check 'T7 step real password: policy failure mapped' (Get-T7Codes) 'SVC_PASSWORD_POLICY:5'
    Check 'T7 step real password: New-LocalUser got the SecureString' $t7Seen['Length'] $t7Secret.Length
    Check 'T7 step real password: variable cleared' ($null -eq [System.Environment]::GetEnvironmentVariable($t7EnvName, 'Process')) 'True'
    Check 'T7 step real password: not in the log' (($script:LogLines -join "`n").Contains($t7Secret)) 'False'
    Check 'T7 step real password: not in the issues' ((Get-T7IssueText).Contains($t7Secret)) 'False'
    Check 'T7 step real password: status MISSING' $t7R.Status 'MISSING'
}
& {
    $script:Issues = New-Object System.Collections.ArrayList
    $t7Cfg = (Get-DefaultConfig).Clone()
    $t7Cfg['PasswordEnvVar'] = $t7EnvName
    [System.Environment]::SetEnvironmentVariable($t7EnvName, $t7Secret, 'Process')
    function Get-ServiceAccountInfo { param([string] $Name) return (New-T7Info) }
    $t7R = Invoke-ServiceAccountStep -Config $t7Cfg -Apply $false -CreateRequested $false
    Check 'T7 step audit: password variable cleared in every mode' ($null -eq [System.Environment]::GetEnvironmentVariable($t7EnvName, 'Process')) 'True'
    Check 'T7 step audit: compliant account gives no issue' (Get-T7Codes) ''
}
[System.Environment]::SetEnvironmentVariable($t7EnvName, $null, 'Process')
$script:Issues = New-Object System.Collections.ArrayList
# --- Task 8: Config file byte IO and atomic write ---
# Static rules for the config file routine (spec 7.8).
& {
    try {
        $fnText = @{}
        foreach ($fn in $ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $fnText[$fn.Name] = $fn.Extent.Text
        }
        Check 'T8 Restore-ConfFile exists and never moves or copies a file into the data folder' ($fnText.ContainsKey('Restore-ConfFile') -and $fnText['Restore-ConfFile'] -notmatch 'Move-Item|Copy-Item|::Move\(|::Copy\(') $true
        Check 'T8 Restore-ConfFile writes through Write-ConfFileAtomic' ($fnText.ContainsKey('Restore-ConfFile') -and $fnText['Restore-ConfFile'] -match 'Write-ConfFileAtomic') $true
        Check 'T8 Write-ConfFileAtomic swaps with [IO.File]::Replace' ($fnText.ContainsKey('Write-ConfFileAtomic') -and $fnText['Write-ConfFileAtomic'] -match '\[System\.IO\.File\]::Replace\(') $true
        Check 'T8 Write-ConfFileAtomic never passes a null backup path to Replace' ($fnText.ContainsKey('Write-ConfFileAtomic') -and $fnText['Write-ConfFileAtomic'] -notmatch '::Replace\([^)]*\$null') $true
        $ioText = ''
        foreach ($name in @('Write-ConfFileAtomic', 'Backup-ConfFile', 'Restore-ConfFile')) {
            if ($fnText.ContainsKey($name)) { $ioText += $fnText[$name] }
        }
        Check 'T8 config file writers never write text or a BOM' (($ioText.Length -gt 0) -and ($ioText -notmatch 'WriteAllText|Set-Content|Add-Content|UTF8')) $true
    } catch {
        Check 'T8 static checks ran without an error' $_.Exception.Message ''
    }
}

# Latin-1 and SHA-256.
& {
    try {
        $all = New-Object byte[] 256
        for ($i = 0; $i -lt 256; $i++) { $all[$i] = [byte]$i }
        $allText = ConvertFrom-Latin1Bytes -Bytes $all
        Check 'T8 Latin-1 decode gives one char per byte' $allText.Length 256
        Check 'T8 Latin-1 byte 0x80 decodes to U+0080' ([int]$allText[128]) 128
        Check 'T8 Latin-1 byte 0xE9 decodes to U+00E9' ([int]$allText[233]) 233
        $allBack = ConvertTo-Latin1Bytes -Text $allText
        Check 'T8 Latin-1 encode returns one byte[]' ($allBack -is [byte[]]) $true
        Check 'T8 Latin-1 round trip keeps all 256 byte values' (Get-Sha256Hex -Bytes $allBack) (Get-Sha256Hex -Bytes $all)
        Check 'T8 Latin-1 decode of no bytes is empty' (ConvertFrom-Latin1Bytes -Bytes (New-Object byte[] 0)) ''
        Check 'T8 Latin-1 encode of empty text gives no bytes' ((ConvertTo-Latin1Bytes -Text '').Length) 0
        Throws 'T8 Latin-1 encode refuses a char above U+00FF' { ConvertTo-Latin1Bytes -Text ('euro ' + [char]0x20AC) }
        Check 'T8 SHA-256 of abc' (Get-Sha256Hex -Bytes ([System.Text.Encoding]::ASCII.GetBytes('abc'))) 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        Check 'T8 SHA-256 of no bytes' (Get-Sha256Hex -Bytes (New-Object byte[] 0)) 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    } catch {
        Check 'T8 Latin-1 and SHA-256 checks ran without an error' $_.Exception.Message ''
    }
}

# Read -> Split -> Join -> ConvertTo-Latin1Bytes keeps every byte (CRLF, LF, BOM,
# CP1252 and UTF-8 bytes in comments).
& {
    try {
        $latin1 = [System.Text.Encoding]::GetEncoding(28591)
        $dir = New-TestFolder 't8io'
        # Two comments with non-ASCII bytes: CP1252 e-acute, euro and an undefined 0x9D,
        # then UTF-8 e-acute and euro.
        $body = {
            param([string] $Eol)
            ,([byte[]]($latin1.GetBytes("# pg_hba.conf fixture$Eol# CP1252: caf") + [byte[]](0xE9, 0x20, 0x80, 0x20, 0x9D) +
                $latin1.GetBytes("$Eol# UTF-8: caf") + [byte[]](0xC3, 0xA9, 0x20, 0xE2, 0x82, 0xAC) +
                $latin1.GetBytes("${Eol}host    all    all    127.0.0.1/32    sspi map=veeam$Eol")))
        }
        $roundTrip = {
            param([string] $File)
            $read = Read-ConfFile -Path $File
            $text = Join-ConfLines -Lines @(Split-ConfLines -Text $read.Text) -LineEnding $read.LineEnding
            ConvertTo-Latin1Bytes -Text $text
        }

        $crlf = Join-Path $dir 'crlf.conf'
        $crlfBytes = & $body "`r`n"
        [System.IO.File]::WriteAllBytes($crlf, $crlfBytes)
        $read = Read-ConfFile -Path $crlf
        Check 'T8 Read-ConfFile returns the full path' $read.Path ([System.IO.Path]::GetFullPath($crlf))
        Check 'T8 Read-ConfFile keeps the raw bytes' (Get-Sha256Hex -Bytes $read.Bytes) (Get-Sha256Hex -Bytes $crlfBytes)
        Check 'T8 Read-ConfFile Text is the Latin-1 text of the bytes' ($read.Text -ceq $latin1.GetString($crlfBytes)) $true
        Check 'T8 Read-ConfFile finds CRLF' ($read.LineEnding -ceq "`r`n") $true
        Check 'T8 Read-ConfFile finds no BOM' $read.HadBom $false
        Check 'T8 Read-ConfFile records the SDDL' $read.Sddl ((Get-Acl -LiteralPath $crlf).Sddl)
        $lines = @(Split-ConfLines -Text $read.Text)
        Check 'T8 CRLF file splits into 4 lines' $lines.Count 4
        Check 'T8 split lines carry no CR' (($lines -join '|').Contains("`r")) $false
        Check 'T8 CRLF round trip is byte-exact' (Get-Sha256Hex -Bytes (& $roundTrip $crlf)) (Get-Sha256Hex -Bytes $crlfBytes)

        $lf = Join-Path $dir 'lf.conf'
        $lfBytes = & $body "`n"
        [System.IO.File]::WriteAllBytes($lf, $lfBytes)
        Check 'T8 Read-ConfFile finds LF' ((Read-ConfFile -Path $lf).LineEnding -ceq "`n") $true
        Check 'T8 LF round trip is byte-exact' (Get-Sha256Hex -Bytes (& $roundTrip $lf)) (Get-Sha256Hex -Bytes $lfBytes)

        $bom = Join-Path $dir 'bom.conf'
        [System.IO.File]::WriteAllBytes($bom, [byte[]]([byte[]](0xEF, 0xBB, 0xBF) + $crlfBytes))
        $bomRead = Read-ConfFile -Path $bom
        Check 'T8 Read-ConfFile finds the BOM' $bomRead.HadBom $true
        Check 'T8 Read-ConfFile keeps the BOM in Bytes' $bomRead.Bytes.Length ($crlfBytes.Length + 3)
        Check 'T8 Read-ConfFile Text has no BOM' ($bomRead.Text -ceq $latin1.GetString($crlfBytes)) $true
        Check 'T8 BOM file round trip drops only the BOM' (Get-Sha256Hex -Bytes (& $roundTrip $bom)) (Get-Sha256Hex -Bytes $crlfBytes)

        $noFinal = Join-Path $dir 'nofinal.conf'
        [System.IO.File]::WriteAllBytes($noFinal, $latin1.GetBytes("a`r`nb"))
        Check 'T8 a missing final line break is added' (Get-Sha256Hex -Bytes (& $roundTrip $noFinal)) (Get-Sha256Hex -Bytes $latin1.GetBytes("a`r`nb`r`n"))

        $mixed = Join-Path $dir 'mixed.conf'
        [System.IO.File]::WriteAllBytes($mixed, $latin1.GetBytes("a`nb`r`nc`n"))
        Check 'T8 the first line break decides the line ending' ((Read-ConfFile -Path $mixed).LineEnding -ceq "`n") $true
        Check 'T8 mixed line endings become the first one' (Get-Sha256Hex -Bytes (& $roundTrip $mixed)) (Get-Sha256Hex -Bytes $latin1.GetBytes("a`nb`nc`n"))

        $empty = Join-Path $dir 'empty.conf'
        [System.IO.File]::WriteAllBytes($empty, (New-Object byte[] 0))
        $emptyRead = Read-ConfFile -Path $empty
        Check 'T8 empty file reads as empty text' $emptyRead.Text ''
        Check 'T8 empty file round trip stays empty' ((& $roundTrip $empty).Length) 0

        Check 'T8 split keeps an empty middle line' (@(Split-ConfLines -Text "a`r`n`r`nb`r`n") -join '|') 'a||b'
        Check 'T8 split of empty text gives no lines' (@(Split-ConfLines -Text '').Count) 0
        Check 'T8 split keeps a last line without a line break' (@(Split-ConfLines -Text "a`nb") -join '|') 'a|b'
        Check 'T8 split removes only one CR' ((@(Split-ConfLines -Text "a`r`r`n"))[0] -ceq "a`r") $true
        Check 'T8 join ends with one line ending' ((Join-ConfLines -Lines @('a', 'b') -LineEnding "`r`n") -ceq "a`r`nb`r`n") $true
        Check 'T8 join of no lines is empty' (Join-ConfLines -Lines @() -LineEnding "`n") ''
        Throws 'T8 join refuses a line ending that is not LF or CRLF' { Join-ConfLines -Lines @('a') -LineEnding "`r" }
    } catch {
        Check 'T8 read, split and join checks ran without an error' $_.Exception.Message ''
    }
}

# Write-ConfFileAtomic keeps the SDDL, and puts the previous bytes back on any failure.
& {
    try {
        $latin1 = [System.Text.Encoding]::GetEncoding(28591)
        $data = New-TestFolder 't8data'
        $live = Join-Path $data 'pg_hba.conf'
        [System.IO.File]::WriteAllBytes($live, $latin1.GetBytes("# original`r`nhost all all 127.0.0.1/32 scram-sha-256`r`n"))
        # A distinctive ACL, like a real data folder file that this run did not create:
        # owner and group SYSTEM, protected DACL with a NetworkService read entry. A new
        # file in this folder gets none of these (owner Administrators, inherited DACL).
        $acl = Get-Acl -LiteralPath $live
        $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:PAI(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;NS)')
        Set-Acl -LiteralPath $live -AclObject $acl
        $sddl = (Get-Acl -LiteralPath $live).Sddl
        Check 'T8 fixture ACL is distinctive' (($sddl -like 'O:SYG:SYD:PAI*') -and ($sddl -like '*;;;NS)*')) $true
        $probe = Join-Path $data 'probe.bin'
        [System.IO.File]::WriteAllBytes($probe, [byte[]](1))
        Check 'T8 a new file in the folder gets another SDDL' ((Get-Acl -LiteralPath $probe).Sddl -cne $sddl) $true
        [System.IO.File]::Delete($probe)
        $others = { @(Get-ChildItem -LiteralPath $data -Force | Where-Object { $_.Name -ne 'pg_hba.conf' }).Count }

        $new = $latin1.GetBytes("# new`r`nlocal all all sspi map=veeam`r`n")
        Write-ConfFileAtomic -Path $live -Bytes $new -ExpectedSddl $sddl
        Check 'T8 atomic write puts the new bytes in place' (Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($live))) (Get-Sha256Hex -Bytes $new)
        Check 'T8 atomic write keeps owner, group and DACL' ((Get-Acl -LiteralPath $live).Sddl) $sddl
        Check 'T8 atomic write leaves no temp or backup file' (& $others) 0
        $wrote = "Wrote '$([System.IO.Path]::GetFullPath($live))'"
        Check 'T8 atomic write logs the write' (@($script:LogLines | Where-Object { $_.Contains($wrote) }).Count -gt 0) $true

        $before = [System.IO.File]::ReadAllBytes($live)
        $other = $latin1.GetBytes("# other`r`n")
        $err = ''
        try { Write-ConfFileAtomic -Path $live -Bytes $other -ExpectedSddl 'O:BAG:BAD:PAI(A;;FA;;;BA)' } catch { $err = $_.Exception.Message }
        Check 'T8 an SDDL mismatch throws and says the previous bytes were put back' ($err -like '*SDDL*previous bytes were put back*') $true
        Check 'T8 after an SDDL mismatch the previous bytes are back' (Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($live))) (Get-Sha256Hex -Bytes $before)
        Check 'T8 after an SDDL mismatch the SDDL is unchanged' ((Get-Acl -LiteralPath $live).Sddl) $sddl
        Check 'T8 after an SDDL mismatch no temp or backup file is left' (& $others) 0

        # Another process holds the file without delete sharing (like an AV scanner):
        # File.Replace fails and the live file stays as it was.
        $lock = [System.IO.File]::Open($live, 'Open', 'Read', 'ReadWrite')
        $err = ''
        try {
            try { Write-ConfFileAtomic -Path $live -Bytes $other -ExpectedSddl $sddl } catch { $err = $_.Exception.Message }
        } finally {
            $lock.Dispose()
        }
        Check 'T8 a blocked swap throws and says the file is unchanged' ($err -like '*swap failed*still holds its previous bytes*') $true
        Check 'T8 after a blocked swap the previous bytes are there' (Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($live))) (Get-Sha256Hex -Bytes $before)
        Check 'T8 after a blocked swap no temp or backup file is left' (& $others) 0

        $missing = Join-Path $data 'pg_ident.conf'
        Throws 'T8 atomic write refuses a file that does not exist' { Write-ConfFileAtomic -Path $missing -Bytes $new -ExpectedSddl $sddl }
        Check 'T8 a refused write creates nothing' (Test-Path -LiteralPath $missing) $false

        $emptyBytes = New-Object byte[] 0
        Write-ConfFileAtomic -Path $live -Bytes $emptyBytes -ExpectedSddl $sddl
        Check 'T8 atomic write can write an empty file' ((Get-Item -LiteralPath $live).Length) 0
        Write-ConfFileAtomic -Path $live -Bytes $before -ExpectedSddl $sddl

        # The usual data folder case: the file has only ACEs inherited from a folder with
        # its own ACL, and its owner and group are not this identity's defaults.
        $inherit = New-TestFolder 't8inherit'
        $folderAcl = Get-Acl -LiteralPath $inherit
        $folderAcl.SetSecurityDescriptorSddlForm('D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;NS)', [System.Security.AccessControl.AccessControlSections]::Access)
        Set-Acl -LiteralPath $inherit -AclObject $folderAcl
        $inheritFile = Join-Path $inherit 'pg_hba.conf'
        [System.IO.File]::WriteAllBytes($inheritFile, $latin1.GetBytes("host all all 127.0.0.1/32 md5`n"))
        $fileAcl = Get-Acl -LiteralPath $inheritFile
        $fileAcl.SetSecurityDescriptorSddlForm('O:SYG:SY', ([System.Security.AccessControl.AccessControlSections]'Owner, Group'))
        Set-Acl -LiteralPath $inheritFile -AclObject $fileAcl
        $inheritRead = Read-ConfFile -Path $inheritFile
        Check 'T8 inherited fixture has only inherited ACEs' (($inheritRead.Sddl -like 'O:SYG:SYD:AI(A;ID;*') -and ($inheritRead.Sddl -notlike '*(A;;*')) $true
        Write-ConfFileAtomic -Path $inheritFile -Bytes $new -ExpectedSddl $inheritRead.Sddl
        Check 'T8 atomic write keeps an inherited ACL with its owner and group' ((Get-Acl -LiteralPath $inheritFile).Sddl) $inheritRead.Sddl
        Check 'T8 atomic write on the inherited file puts the new bytes in place' (Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($inheritFile))) (Get-Sha256Hex -Bytes $new)
    } catch {
        Check 'T8 atomic write checks ran without an error' $_.Exception.Message ''
    }
}

# Backup-ConfFile and Restore-ConfFile.
& {
    try {
        $latin1 = [System.Text.Encoding]::GetEncoding(28591)
        $data = New-TestFolder 't8restore'
        $run = New-TestFolder 't8run'
        $runAcl = Get-Acl -LiteralPath $run
        $runAcl.SetSecurityDescriptorSddlForm('D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)', [System.Security.AccessControl.AccessControlSections]::Access)
        Set-Acl -LiteralPath $run -AclObject $runAcl
        $live = Join-Path $data 'pg_ident.conf'
        $original = [byte[]]($latin1.GetBytes("# caf") + [byte[]](0xE9) + $latin1.GetBytes("`r`nveeam `"SYSTEM@NT AUTHORITY`" postgres`r`n"))
        [System.IO.File]::WriteAllBytes($live, $original)
        $acl = Get-Acl -LiteralPath $live
        $acl.SetSecurityDescriptorSddlForm('G:SYD:PAI(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;NS)', ([System.Security.AccessControl.AccessControlSections]'Group, Access'))
        Set-Acl -LiteralPath $live -AclObject $acl
        $sddl = (Get-Acl -LiteralPath $live).Sddl

        $backup = Backup-ConfFile -Path $live -RunDir $run
        Check 'T8 backup path is <RunDir>\<name>.before' $backup (Join-Path ([System.IO.Path]::GetFullPath($run)) 'pg_ident.conf.before')
        Check 'T8 backup holds the exact original bytes' (Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($backup))) (Get-Sha256Hex -Bytes $original)
        Check 'T8 backup file has the run folder ACL, not the live one' ((Get-Acl -LiteralPath $backup).Sddl -cne $sddl) $true
        Throws 'T8 backup never overwrites an existing backup' { Backup-ConfFile -Path $live -RunDir $run }

        Write-ConfFileAtomic -Path $live -Bytes ($latin1.GetBytes("veeam `"SYSTEM@NT AUTHORITY`" postgres`r`n")) -ExpectedSddl $sddl
        Restore-ConfFile -Path $live -BackupPath $backup -ExpectedSddl $sddl
        Check 'T8 restore puts the backup bytes back' (Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($live))) (Get-Sha256Hex -Bytes $original)
        Check 'T8 restore keeps the live SDDL, not the run folder ACL' ((Get-Acl -LiteralPath $live).Sddl) $sddl
        Check 'T8 restore leaves no temp or backup file in the data folder' (@(Get-ChildItem -LiteralPath $data -Force).Count) 1
        $logCount = $script:LogLines.Count
        Restore-ConfFile -Path $live -BackupPath $backup -ExpectedSddl $sddl
        Check 'T8 restoring identical bytes writes nothing' (@($script:LogLines | Select-Object -Skip $logCount | Where-Object { $_ -like '*Nothing to restore*' }).Count) 1
        Throws 'T8 restore with a wrong SDDL throws' { Restore-ConfFile -Path $live -BackupPath $backup -ExpectedSddl 'O:BAG:BAD:PAI(A;;FA;;;BA)' }
        Check 'T8 a failed restore leaves the live bytes as they were' (Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($live))) (Get-Sha256Hex -Bytes $original)
    } catch {
        Check 'T8 backup and restore checks ran without an error' $_.Exception.Message ''
    }
}
# --- Task 9: pg_hba.conf parse, check and render ---
# Fixtures, shared by the Task 9 groups below.
# Stock PostgreSQL file from a native-auth install: scram-sha-256 everywhere.
$T9Native = @'
# PostgreSQL Client Authentication Configuration File
# ===================================================
#
# Refer to the "Client Authentication" section in the PostgreSQL
# documentation for a complete description of this file.

# TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
local   all             all                                     scram-sha-256
# IPv4 local connections:
host    all             all             127.0.0.1/32            scram-sha-256
# IPv6 local connections:
host    all             all             ::1/128                 scram-sha-256
# Allow replication connections from localhost, by a user with the
# replication privilege.
local   replication     all                                     scram-sha-256
host    replication     all             127.0.0.1/32            scram-sha-256
host    replication     all             ::1/128                 scram-sha-256
'@
# Veeam's default SSPI file (KB4818, spec 7.3).
$T9Veeam = @'
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
local   all             all                                     sspi map=veeam
# IPv4 local connections:
host    all             all             127.0.0.1/32            sspi map=veeam
# IPv6 local connections:
host    all             all             ::1/128                 sspi map=veeam
# Allow replication connections from localhost, by a user with the
# replication privilege.
local   replication     all                                     sspi map=veeam
host    replication     all             127.0.0.1/32            sspi map=veeam
host    replication     all             ::1/128                 sspi map=veeam
'@
# VBR-PILOT01: split by role. postgres uses SSPI, every other role (pg_native_admin)
# uses a password. The postgres lines sit above all the scram lines.
$T9Pilot = @'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# postgres (VBR services, SYSTEM) uses Windows authentication
local   all             postgres                                sspi map=veeam
host    all             postgres        127.0.0.1/32            sspi map=veeam
host    all             postgres        ::1/128                 sspi map=veeam
local   replication     postgres                                sspi map=veeam
host    replication     postgres        127.0.0.1/32            sspi map=veeam
host    replication     postgres        ::1/128                 sspi map=veeam
# every other role uses a password
local   all             all                                     scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
local   replication     all                                     scram-sha-256
host    replication     all             127.0.0.1/32            scram-sha-256
host    replication     all             ::1/128                 scram-sha-256
'@
# Veeam default plus a LAN line.
$T9Lan = $T9Veeam + "`n" + 'host    all             all             10.0.0.0/24             scram-sha-256'
# Address and netmask columns.
$T9Netmask = @'
host    all             all             127.0.0.1 255.255.255.255   sspi map=veeam
host    all             all             192.168.1.0 255.255.255.0   md5
host    all             all             fe80:: ffff:ffff:ffff:ffff::   md5
'@
# Include directives (PostgreSQL 16 and later) and @file lists.
$T9IncludeDir = $T9Veeam + "`n" + 'include_dir conf.d'
$T9IncludeFile = 'include "extra.conf"' + "`n" + $T9Veeam
$T9AtFile = 'host    all             @admins.txt     127.0.0.1/32            md5'
$T9Stamp = '20261012-101500'
$T9Prefix = "# [VbrStandardise $T9Stamp] "

# Split-ConfTokens.
& {
    try {
        Check 'T9 tokens of a host line' (@(Split-ConfTokens -Line 'host  all all 127.0.0.1/32   sspi map=veeam') -join '|') 'host|all|all|127.0.0.1/32|sspi|map=veeam'
        Check 'T9 tabs separate tokens' (@(Split-ConfTokens -Line "host`tall`tall`t::1/128`tsspi") -join '|') 'host|all|all|::1/128|sspi'
        Check 'T9 a trailing comment is dropped' (@(Split-ConfTokens -Line 'local all all sspi # was md5') -join '|') 'local|all|all|sspi'
        Check 'T9 a comment line has no tokens' (@(Split-ConfTokens -Line '# host all all 10.0.0.0/8 md5').Count) 0
        Check 'T9 a blank line has no tokens' (@(Split-ConfTokens -Line '   ').Count) 0
        Check 'T9 an empty line has no tokens' (@(Split-ConfTokens -Line '').Count) 0
        Check 'T9 quotes keep a token whole and are removed' (@(Split-ConfTokens -Line 'veeam   "SYSTEM@NT AUTHORITY"   postgres') -join '|') 'veeam|SYSTEM@NT AUTHORITY|postgres'
        Check 'T9 # inside quotes is not a comment' (@(Split-ConfTokens -Line 'host all "a#b" 10.0.0.0/8 md5') -join '|') 'host|all|a#b|10.0.0.0/8|md5'
        Check 'T9 a non-breaking space is not a separator' (@(Split-ConfTokens -Line ('a' + [char]0xA0 + 'b c')).Count) 2
        Check 'T9 whitespace after a comma keeps a list in one token' (@(Split-ConfTokens -Line 'host all other, postgres 127.0.0.1/32 md5') -join '|') 'host|all|other,postgres|127.0.0.1/32|md5'
        Check 'T9 whitespace after a comma also joins quoted list items' (@(Split-ConfTokens -Line 'host "VeeamBackup",   other all 127.0.0.1/32 md5') -join '|') 'host|VeeamBackup,other|all|127.0.0.1/32|md5'
        Check 'T9 a comma inside quotes does not join the next token' (@(Split-ConfTokens -Line 'host all "a," b md5') -join '|') 'host|all|a,|b|md5'
        Check 'T9 a trailing comma before a comment stays on its token' (@(Split-ConfTokens -Line 'host all other, # c') -join '|') 'host|all|other,'
    } catch {
        Check 'T9 token checks ran without an error' $_.Exception.Message ''
    }
}

# Get-ConfLogicalLines.
& {
    try {
        $join = @(Get-ConfLogicalLines -Lines @('host all \', 'postgres 127.0.0.1/32 md5', 'host all all ::1/128 sspi'))
        Check 'T9 a trailing backslash joins the next line' ('{0}|{1}|{2}' -f $join.Count, $join[0].LineIndex, $join[0].Text) '2|0|host all postgres 127.0.0.1/32 md5'
        Check 'T9 the line after a joined pair keeps its own line index' $join[1].LineIndex 2
        $chain = @(Get-ConfLogicalLines -Lines @('host all \', 'postgres \', '127.0.0.1/32 md5', 'local all all peer'))
        Check 'T9 a chain of backslash lines is one line' ('{0}|{1}|{2}' -f $chain.Count, $chain[0].Text, $chain[1].LineIndex) '2|host all postgres 127.0.0.1/32 md5|3'
        $comment = @(Get-ConfLogicalLines -Lines @('# data is in C:\pgdata\', 'host all all 127.0.0.1/32 md5'))
        Check 'T9 a comment ending in a backslash does not swallow the next line' ('{0}|{1}' -f $comment.Count, $comment[1].Text) '2|host all all 127.0.0.1/32 md5'
        $last = @(Get-ConfLogicalLines -Lines @('local all all md5 \'))
        Check 'T9 a backslash on the last line is dropped' ('{0}|{1}' -f $last.Count, $last[0].Text) '1|local all all md5 '
        $blanks = @(Get-ConfLogicalLines -Lines @('local all all md5 \ ', 'host all all ::1/128 md5'))
        Check 'T9 a backslash followed by a blank is not a continuation' $blanks.Count 2
        $inner = @(Get-ConfLogicalLines -Lines @('host all DOM\bob 127.0.0.1/32 md5'))
        Check 'T9 a backslash inside a line is an ordinary character' $inner[0].Text 'host all DOM\bob 127.0.0.1/32 md5'
        Check 'T9 no lines give no logical lines' (@(Get-ConfLogicalLines -Lines @()).Count) 0
    } catch {
        Check 'T9 logical line checks ran without an error' $_.Exception.Message ''
    }
}

# Get-PgHbaRules and Test-PgHbaHasInclude.
& {
    try {
        $native = @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Native))
        Check 'T9 stock native file has 6 rules' $native.Count 6
        Check 'T9 rule 1 is the local line' ('{0}|{1}|{2}|{3}|{4}|{5}' -f $native[0].Type, $native[0].Database, $native[0].User, $native[0].Address, $native[0].Method, $native[0].Options) 'local|all|all||scram-sha-256|'
        Check 'T9 rule 1 points at its line' $native[0].LineIndex 9
        Check 'T9 rule 2 is host 127.0.0.1/32' ('{0}|{1}|{2}' -f $native[1].Type, $native[1].Address, $native[1].Method) 'host|127.0.0.1/32|scram-sha-256'
        Check 'T9 rule 6 is host replication ::1/128' ('{0}|{1}|{2}|{3}' -f $native[5].Type, $native[5].Database, $native[5].Address, $native[5].LineIndex) 'host|replication|::1/128|18'
        $veeam = @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Veeam))
        Check 'T9 sspi rule keeps map=veeam in Options' ('{0}|{1}' -f $veeam[1].Method, $veeam[1].Options) 'sspi|map=veeam'
        $mask = @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Netmask))
        Check 'T9 127.0.0.1 + 255.255.255.255 becomes 127.0.0.1/32' ('{0}|{1}|{2}' -f $mask[0].Address, $mask[0].Method, $mask[0].Options) '127.0.0.1/32|sspi|map=veeam'
        Check 'T9 192.168.1.0 + 255.255.255.0 becomes /24' ('{0}|{1}' -f $mask[1].Address, $mask[1].Method) '192.168.1.0/24|md5'
        Check 'T9 an IPv6 netmask becomes /64' ('{0}|{1}' -f $mask[2].Address, $mask[2].Method) 'fe80::/64|md5'
        $named = @(Get-PgHbaRules -Lines @('host all all .corp.local md5', 'host all all samehost scram-sha-256', 'hostssl all all all md5'))
        Check 'T9 a host name address has no netmask column' ('{0}|{1}' -f $named[0].Address, $named[0].Method) '.corp.local|md5'
        Check 'T9 samehost is kept as the address' ('{0}|{1}' -f $named[1].Address, $named[1].Method) 'samehost|scram-sha-256'
        Check 'T9 hostssl is a rule type' ('{0}|{1}' -f $named[2].Type, $named[2].Address) 'hostssl|all'
        $include = @(Get-PgHbaRules -Lines @('include_dir conf.d'))
        Check 'T9 an include line is still a rule' ('{0}|{1}' -f $include[0].Type, $include[0].Database) 'include_dir|conf.d'
        Check 'T9 no rules from comments only' (@(Get-PgHbaRules -Lines @('# nothing', '')).Count) 0
        $cont = @(Get-PgHbaRules -Lines @('host all \', 'postgres 127.0.0.1/32 md5', 'host all all 127.0.0.1/32 sspi map=veeam'))
        Check 'T9 a backslash-continued line is one rule with the first line index' ('{0}|{1}|{2}|{3}|{4}|{5}' -f $cont.Count, $cont[0].Database, $cont[0].User, $cont[0].Address, $cont[0].Method, $cont[0].LineIndex) '2|all|postgres|127.0.0.1/32|md5|0'
        Check 'T9 the rule after a continued line keeps its own line index' $cont[1].LineIndex 2

        Check 'T9 stock native file has no include' (Test-PgHbaHasInclude -Lines @(Split-ConfLines -Text $T9Native)) $false
        Check 'T9 Veeam default file has no include' (Test-PgHbaHasInclude -Lines @(Split-ConfLines -Text $T9Veeam)) $false
        Check 'T9 include_dir is an include' (Test-PgHbaHasInclude -Lines @(Split-ConfLines -Text $T9IncludeDir)) $true
        Check 'T9 include "file" is an include' (Test-PgHbaHasInclude -Lines @(Split-ConfLines -Text $T9IncludeFile)) $true
        Check 'T9 include_if_exists is an include' (Test-PgHbaHasInclude -Lines @('include_if_exists extra.conf')) $true
        Check 'T9 @file in the user column is an include' (Test-PgHbaHasInclude -Lines @($T9AtFile)) $true
        Check 'T9 @file inside a comma list is an include' (Test-PgHbaHasInclude -Lines @('host VeeamBackup,@dbs.txt all 127.0.0.1/32 md5')) $true
        Check 'T9 a commented include is not an include' (Test-PgHbaHasInclude -Lines @('# include_dir conf.d')) $false
        Check 'T9 an include keyword split by a backslash is an include' (Test-PgHbaHasInclude -Lines @('inc\', 'lude "extra.conf"')) $true
    } catch {
        Check 'T9 rule parsing checks ran without an error' $_.Exception.Message ''
    }
}

# Get-StandardPgHbaLines, Test-PgHbaStandard and Get-NonLoopbackHbaRules.
& {
    try {
        $standardLines = @(Get-StandardPgHbaLines)
        Check 'T9 six standard lines' $standardLines.Count 6
        Check 'T9 first standard line' $standardLines[0] 'local   all             all                                     sspi map=veeam'
        Check 'T9 standard lines are standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines $standardLines)) $true
        Check 'T9 Veeam default file is standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Veeam))) $true
        Check 'T9 stock native file is not standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Native))) $false
        Check 'T9 pilot split-by-role file is not standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Pilot))) $false
        Check 'T9 a LAN line makes the file not standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Lan))) $false
        Check 'T9 an include line makes the file not standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9IncludeDir))) $false
        Check 'T9 no rules is not standard' (Test-PgHbaStandard -Rules @()) $false
        Check 'T9 five of six rules is not standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines $standardLines[0..4])) $false
        $swapped = @($standardLines[1], $standardLines[0]) + $standardLines[2..5]
        Check 'T9 the right rules in the wrong order are not standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines $swapped)) $false
        $spaced = @('LOCAL all ALL SSPI map=veeam', 'host all all 127.0.0.1 255.255.255.255 sspi    map=veeam') + $standardLines[2..5]
        Check 'T9 spacing, case and a netmask column do not matter' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines $spaced)) $true
        $mapCase = @('local all all sspi map=Veeam') + $standardLines[1..5]
        Check 'T9 a map name in another case is not standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines $mapCase)) $false
        $extraOption = @('local all all sspi map=veeam include_realm=0') + $standardLines[1..5]
        Check 'T9 an extra option is not standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines $extraOption)) $false
        # Options compare as a set: the same option twice, in any spacing, is one option.
        $optionSet = @("local all all sspi map=veeam`tmap=veeam") + $standardLines[1..5]
        Check 'T9 Options compare as a set of words' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines $optionSet)) $true
        $ruleObjects = @(Get-PgHbaRules -Lines $standardLines | ForEach-Object { @{ Type = $_.Type; Database = $_.Database; User = $_.User; Address = $_.Address; Method = $_.Method; Options = $_.Options } })
        Check 'T9 rules given as hashtables are read too' (Test-PgHbaStandard -Rules $ruleObjects) $true

        Check 'T9 Veeam default file has no non-loopback rule' (@(Get-NonLoopbackHbaRules -Rules @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Veeam))).Count) 0
        Check 'T9 pilot file has no non-loopback rule' (@(Get-NonLoopbackHbaRules -Rules @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Pilot))).Count) 0
        $lan = @(Get-NonLoopbackHbaRules -Rules @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Lan)))
        Check 'T9 the LAN line is the one non-loopback rule' ('{0}|{1}' -f $lan.Count, $lan[0].Address) '1|10.0.0.0/24'
        $maskOther = @(Get-NonLoopbackHbaRules -Rules @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Netmask)))
        Check 'T9 netmask lines: only the 127.0.0.1/32 line is loopback' (@($maskOther | ForEach-Object { $_.Address }) -join ',') '192.168.1.0/24,fe80::/64'
        $odd = @(Get-NonLoopbackHbaRules -Rules @(Get-PgHbaRules -Lines @('host all all samehost md5', 'host all all 127.0.0.0/8 md5', 'host all all 0:0:0:0:0:0:0:1/128 md5', 'local all all md5')))
        Check 'T9 samehost and 127.0.0.0/8 are non-loopback; ::1 in long form is loopback' (@($odd | ForEach-Object { $_.Address }) -join ',') 'samehost,127.0.0.0/8'
    } catch {
        Check 'T9 standard and non-loopback checks ran without an error' $_.Exception.Message ''
    }
}

# Get-HbaFirstMatch.
& {
    try {
        $veeam = @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Veeam))
        $hit = Get-HbaFirstMatch -Rules $veeam -Database 'VeeamBackup' -User 'postgres' -Address '127.0.0.1'
        Check 'T9 Veeam default: 127.0.0.1 matches the IPv4 sspi line' ('{0}|{1}|{2}' -f $hit.LineIndex, $hit.Method, $hit.Options) '5|sspi|map=veeam'
        $hit = Get-HbaFirstMatch -Rules $veeam -Database 'VeeamBackup' -User 'postgres' -Address '::1'
        Check 'T9 Veeam default: ::1 matches the IPv6 sspi line' ('{0}|{1}' -f $hit.LineIndex, $hit.Address) '7|::1/128'
        $hit = Get-HbaFirstMatch -Rules @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Native)) -Database 'VeeamBackup' -User 'postgres' -Address '127.0.0.1'
        Check 'T9 stock native: the first match is scram-sha-256' $hit.Method 'scram-sha-256'
        $pilot = @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Pilot))
        $hit = Get-HbaFirstMatch -Rules $pilot -Database 'VeeamBackup' -User 'postgres' -Address '127.0.0.1'
        Check 'T9 pilot: postgres matches its sspi line' ('{0}|{1}|{2}' -f $hit.LineIndex, $hit.User, $hit.Method) '3|postgres|sspi'
        $hit = Get-HbaFirstMatch -Rules $pilot -Database 'VeeamBackup' -User 'pg_native_admin' -Address '::1'
        Check 'T9 pilot: pg_native_admin matches a scram line' ('{0}|{1}|{2}' -f $hit.LineIndex, $hit.User, $hit.Method) '11|all|scram-sha-256'
        $lan = @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Lan))
        $hit = Get-HbaFirstMatch -Rules $lan -Database 'VeeamBackup' -User 'postgres' -Address '10.0.0.77'
        Check 'T9 LAN: 10.0.0.77 matches 10.0.0.0/24' ('{0}|{1}' -f $hit.Address, $hit.Method) '10.0.0.0/24|scram-sha-256'
        Check 'T9 LAN: 10.0.1.77 matches nothing' ($null -eq (Get-HbaFirstMatch -Rules $lan -Database 'VeeamBackup' -User 'postgres' -Address '10.0.1.77')) $true
        $mask = @(Get-PgHbaRules -Lines @(Split-ConfLines -Text $T9Netmask))
        $hit = Get-HbaFirstMatch -Rules $mask -Database 'VeeamBackup' -User 'postgres' -Address '192.168.1.200'
        Check 'T9 netmask: 192.168.1.200 matches 192.168.1.0/24' $hit.LineIndex 1
        $hit = Get-HbaFirstMatch -Rules $mask -Database 'VeeamBackup' -User 'postgres' -Address 'fe80::1'
        Check 'T9 netmask: fe80::1 matches fe80::/64' $hit.LineIndex 2
        $rules = @(Get-PgHbaRules -Lines @('host replication all 127.0.0.1/32 trust', 'host all all 0.0.0.0/0 md5', 'host all all ::/0 sspi map=veeam'))
        $hit = Get-HbaFirstMatch -Rules $rules -Database 'VeeamBackup' -User 'postgres' -Address '::1'
        Check 'T9 replication lines and IPv4 lines never match an IPv6 client' $hit.LineIndex 2
        $rules = @(Get-PgHbaRules -Lines @('local all all trust', 'host sameuser all 127.0.0.1/32 trust', 'host veeambackup all 127.0.0.1/32 trust', 'host VeeamBackup,postgres pg_native_admin,postgres 127.0.0.1/32 md5'))
        $hit = Get-HbaFirstMatch -Rules $rules -Database 'VeeamBackup' -User 'postgres' -Address '127.0.0.1'
        Check 'T9 local, sameuser and a database name in another case do not match; a comma list does' $hit.LineIndex 3
        $hit = Get-HbaFirstMatch -Rules $rules -Database 'postgres' -User 'postgres' -Address '127.0.0.1'
        Check 'T9 sameuser matches when the database equals the user' $hit.LineIndex 1
        $rules = @(Get-PgHbaRules -Lines @('host all +admins 127.0.0.1/32 md5', 'host all all 127.0.0.1/32 sspi map=veeam'))
        Check 'T9 +group counts as a match (cannot decide offline)' (Get-HbaFirstMatch -Rules $rules -Database 'VeeamBackup' -User 'postgres' -Address '127.0.0.1').LineIndex 0
        $rules = @(Get-PgHbaRules -Lines @('host all all samehost md5', 'host all all 127.0.0.1/32 sspi map=veeam'))
        Check 'T9 samehost counts as a match' (Get-HbaFirstMatch -Rules $rules -Database 'VeeamBackup' -User 'postgres' -Address '127.0.0.1').LineIndex 0
        $rules = @(Get-PgHbaRules -Lines @('hostssl all all 127.0.0.1/32 md5', 'host all all 127.0.0.1/32 sspi map=veeam'))
        Check 'T9 hostssl counts as a match' (Get-HbaFirstMatch -Rules $rules -Database 'VeeamBackup' -User 'postgres' -Address '127.0.0.1').LineIndex 0
        $rules = @(Get-PgHbaRules -Lines @('host all pg_native_admin 127.0.0.1/32 md5', 'host all all 127.0.0.1/32 sspi map=veeam'))
        Check 'T9 another user name does not match' (Get-HbaFirstMatch -Rules $rules -Database 'VeeamBackup' -User 'postgres' -Address '127.0.0.1').LineIndex 1
        $rules = @(Get-PgHbaRules -Lines @('host all other, postgres 127.0.0.1/32 md5', 'host all all 127.0.0.1/32 sspi map=veeam'))
        Check 'T9 a space after a comma keeps a user list whole' (Get-HbaFirstMatch -Rules $rules -Database 'VeeamBackup' -User 'postgres' -Address '127.0.0.1').LineIndex 0
        Check 'T9 a space after a comma: a user outside the list skips the line' (Get-HbaFirstMatch -Rules $rules -Database 'VeeamBackup' -User 'someone' -Address '127.0.0.1').LineIndex 1
        $rules = @(Get-PgHbaRules -Lines @('host VeeamBackup, other all 127.0.0.1/32 md5', 'host all all 127.0.0.1/32 sspi map=veeam'))
        Check 'T9 a space after a comma keeps a database list whole' (Get-HbaFirstMatch -Rules $rules -Database 'VeeamBackup' -User 'postgres' -Address '127.0.0.1').LineIndex 0
        $rules = @(Get-PgHbaRules -Lines @('host all \', 'postgres 127.0.0.1/32 md5', 'host all all 127.0.0.1/32 sspi map=veeam'))
        $hit = Get-HbaFirstMatch -Rules $rules -Database 'VeeamBackup' -User 'postgres' -Address '127.0.0.1'
        Check 'T9 a backslash-continued line is the first match, not the sspi line after it' ('{0}|{1}' -f $hit.LineIndex, $hit.Method) '0|md5'
        Throws 'T9 a client address that is not an IP throws' { Get-HbaFirstMatch -Rules $rules -Database 'VeeamBackup' -User 'postgres' -Address 'localhost' }
    } catch {
        Check 'T9 first-match checks ran without an error' $_.Exception.Message ''
    }
}

# New-PgHbaText.
& {
    try {
        $expected = @'
# Standardised by Invoke-VbrStandardise.ps1 on 20261012-101500
local   all             all                                     sspi map=veeam
host    all             all             127.0.0.1/32            sspi map=veeam
host    all             all             ::1/128                 sspi map=veeam
local   replication     all                                     sspi map=veeam
host    replication     all             127.0.0.1/32            sspi map=veeam
host    replication     all             ::1/128                 sspi map=veeam
# PostgreSQL Client Authentication Configuration File
# ===================================================
#
# Refer to the "Client Authentication" section in the PostgreSQL
# documentation for a complete description of this file.

# TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
# [VbrStandardise 20261012-101500] local   all             all                                     scram-sha-256
# IPv4 local connections:
# [VbrStandardise 20261012-101500] host    all             all             127.0.0.1/32            scram-sha-256
# IPv6 local connections:
# [VbrStandardise 20261012-101500] host    all             all             ::1/128                 scram-sha-256
# Allow replication connections from localhost, by a user with the
# replication privilege.
# [VbrStandardise 20261012-101500] local   replication     all                                     scram-sha-256
# [VbrStandardise 20261012-101500] host    replication     all             127.0.0.1/32            scram-sha-256
# [VbrStandardise 20261012-101500] host    replication     all             ::1/128                 scram-sha-256
'@
        $out = New-PgHbaText -Lines @(Split-ConfLines -Text $T9Native) -LineEnding "`r`n" -Stamp $T9Stamp
        Check 'T9 stock native file renders exactly as expected (CRLF)' ($out -ceq (Join-ConfLines -Lines @(Split-ConfLines -Text $expected) -LineEnding "`r`n")) $true
        Check 'T9 CRLF output has no lone LF' (($out -replace "`r`n", '').Contains("`n")) $false
        $outLines = @(Split-ConfLines -Text $out)
        Check 'T9 rendered native file is standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines $outLines)) $true

        $pilotLines = @(Split-ConfLines -Text $T9Pilot)
        $pilotOut = @(Split-ConfLines -Text (New-PgHbaText -Lines $pilotLines -LineEnding "`n" -Stamp $T9Stamp))
        Check 'T9 rendered pilot file is standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines $pilotOut)) $true
        Check 'T9 rendered pilot file keeps every original line' $pilotOut.Count (1 + 6 + $pilotLines.Count)
        Check 'T9 pilot sspi postgres line is commented out' ($pilotOut -ccontains ($T9Prefix + 'host    all             postgres        127.0.0.1/32            sspi map=veeam')) $true
        Check 'T9 pilot comment line is unchanged' ($pilotOut -ccontains '# every other role uses a password') $true
        Check 'T9 LF output has no CR' ((New-PgHbaText -Lines $pilotLines -LineEnding "`n" -Stamp $T9Stamp).Contains("`r")) $false

        $lanOut = @(Split-ConfLines -Text (New-PgHbaText -Lines @(Split-ConfLines -Text $T9Lan) -LineEnding "`r`n" -Stamp $T9Stamp))
        Check 'T9 the LAN line is commented out' ($lanOut -ccontains ($T9Prefix + 'host    all             all             10.0.0.0/24             scram-sha-256')) $true
        Check 'T9 rendered LAN file has no non-loopback rule' (@(Get-NonLoopbackHbaRules -Rules @(Get-PgHbaRules -Lines $lanOut)).Count) 0

        $contOut = @(Split-ConfLines -Text (New-PgHbaText -Lines @('host all \', 'postgres 127.0.0.1/32 md5') -LineEnding "`n" -Stamp $T9Stamp))
        Check 'T9 a backslash-continued original is commented out line by line' (($contOut[7] -ceq ($T9Prefix + 'host all \')) -and ($contOut[8] -ceq ($T9Prefix + 'postgres 127.0.0.1/32 md5'))) $true
        Check 'T9 a rendered backslash-continued original leaves the file standard' (Test-PgHbaStandard -Rules @(Get-PgHbaRules -Lines $contOut)) $true

        # CP1252 and UTF-8 bytes in a comment line and in an active line's trailing
        # comment survive byte for byte; only the ASCII prefix is added.
        $latin1 = [System.Text.Encoding]::GetEncoding(28591)
        $commentBytes = [byte[]]($latin1.GetBytes('# caf') + [byte[]](0xE9, 0x20, 0x80) + $latin1.GetBytes(' UTF-8 ') + [byte[]](0xC3, 0xA9))
        $activeBytes = [byte[]]($latin1.GetBytes('host all all 10.0.0.0/8 md5 # Caf') + [byte[]](0xE9))
        $fileBytes = [byte[]]($commentBytes + [byte[]](13, 10) + $activeBytes + [byte[]](13, 10))
        $outBytes = ConvertTo-Latin1Bytes -Text (New-PgHbaText -Lines @(Split-ConfLines -Text (ConvertFrom-Latin1Bytes -Bytes $fileBytes)) -LineEnding "`r`n" -Stamp $T9Stamp)
        $hex = { param([byte[]] $B) '-' + [System.BitConverter]::ToString($B) + '-' }
        Check 'T9 a comment with CP1252 and UTF-8 bytes survives byte for byte' ((& $hex $outBytes).Contains((& $hex ([byte[]]($commentBytes + [byte[]](13, 10)))))) $true
        Check 'T9 a commented-out active line keeps its bytes after the ASCII prefix' ((& $hex $outBytes).Contains((& $hex ([byte[]]($latin1.GetBytes($T9Prefix) + $activeBytes + [byte[]](13, 10)))))) $true
        Check 'T9 rendering adds no non-ASCII byte' (@($outBytes | Where-Object { $_ -ge 0x80 }).Count) (@($fileBytes | Where-Object { $_ -ge 0x80 }).Count)
        Throws 'T9 a stamp that is not ASCII is refused' { New-PgHbaText -Lines @('local all all md5') -LineEnding "`n" -Stamp ('2026' + [char]0xE9) }
    } catch {
        Check 'T9 render checks ran without an error' $_.Exception.Message ''
    }
}
# --- Task 10: pg_ident.conf parse, check and render ---
# Fixtures, shared by the Task 10 groups below.
# Stock PostgreSQL file from a native-auth install: comments only.
$T10Empty = @'
# PostgreSQL User Name Maps
# =========================
#
# Refer to the PostgreSQL documentation, chapter "Client
# Authentication" for a complete description.

# Put your actual configuration here
# ----------------------------------

# MAPNAME       SYSTEM-USERNAME         PG-USERNAME
'@
# Veeam's default SSPI file (KB4818): SYSTEM plus the account that ran the installer.
$T10Veeam = @'
# MAPNAME       SYSTEM-USERNAME         PG-USERNAME
veeam   "SYSTEM@NT AUTHORITY"   postgres
veeam   Administrator@DOMAIN   postgres
'@
# VBR-PILOT01: SYSTEM, the built-in Administrator and svc_veeam.
$T10Pilot = @'
# MAPNAME       SYSTEM-USERNAME         PG-USERNAME
veeam   "SYSTEM@NT AUTHORITY"   postgres
veeam   Administrator@VBR-PILOT01   postgres
veeam   "svc_veeam@VBR-PILOT01"   postgres
'@
# A line in another map, which is never touched.
$T10OtherMap = @'
veeam   "SYSTEM@NT AUTHORITY"   postgres
veeam   "svc_veeam@VBR-PILOT01"   postgres
pgadmins   "jdoe@CORP"   pg_native_admin
Veeam   "Administrator@VBR-PILOT01"   postgres
'@
# A veeam line that maps svc_veeam to another role.
$T10OtherRole = @'
veeam   "SYSTEM@NT AUTHORITY"   postgres
veeam   "svc_veeam@VBR-PILOT01"   pg_native_admin
'@
$T10Svc = 'svc_veeam@VBR-PILOT01'
$T10Stamp = '20261012-101500'
$T10Prefix = "# [VbrStandardise $T10Stamp] "

# Get-PgIdentEntries and Get-RequiredIdentNames.
& {
    try {
        Check 'T10 a comments-only file has no entries' (@(Get-PgIdentEntries -Lines @(Split-ConfLines -Text $T10Empty)).Count) 0
        $pilot = @(Get-PgIdentEntries -Lines @(Split-ConfLines -Text $T10Pilot))
        Check 'T10 pilot file has 3 entries' $pilot.Count 3
        Check 'T10 entry fields with quotes removed' ('{0}|{1}|{2}|{3}' -f $pilot[0].LineIndex, $pilot[0].Map, $pilot[0].SystemUser, $pilot[0].PgUser) '1|veeam|SYSTEM@NT AUTHORITY|postgres'
        Check 'T10 an unquoted name is read as is' $pilot[1].SystemUser 'Administrator@VBR-PILOT01'
        $short = @(Get-PgIdentEntries -Lines @('veeam "a@B" postgres # note', 'veeam'))
        Check 'T10 a trailing comment is ignored' ('{0}|{1}|{2}' -f $short[0].Map, $short[0].SystemUser, $short[0].PgUser) 'veeam|a@B|postgres'
        Check 'T10 a short line gets empty fields' ('{0}|{1}|{2}' -f $short[1].Map, $short[1].SystemUser, $short[1].PgUser) 'veeam||'

        Check 'T10 required names: SYSTEM then svc_veeam' (@(Get-RequiredIdentNames -SvcMapName $T10Svc) -join '|') 'SYSTEM@NT AUTHORITY|svc_veeam@VBR-PILOT01'
        Check 'T10 required names: service accounts last, duplicates removed case-insensitively' (@(Get-RequiredIdentNames -SvcMapName $T10Svc -ServiceAccountMapNames @('veeamsvc@CORP', 'system@nt authority', 'VEEAMSVC@corp', 'SVC_VEEAM@vbr-pilot01')) -join '|') 'SYSTEM@NT AUTHORITY|svc_veeam@VBR-PILOT01|veeamsvc@CORP'
        Check 'T10 required names skip an empty svc_veeam name' (@(Get-RequiredIdentNames -SvcMapName '' -ServiceAccountMapNames @('veeamsvc@CORP')) -join '|') 'SYSTEM@NT AUTHORITY|veeamsvc@CORP'
        Check 'T10 required names accept a null svc_veeam name' (@(Get-RequiredIdentNames -SvcMapName $null) -join '|') 'SYSTEM@NT AUTHORITY'
    } catch {
        Check 'T10 entry and required-name checks ran without an error' $_.Exception.Message ''
    }
}

# Get-PgIdentStatus.
& {
    try {
        $required = @(Get-RequiredIdentNames -SvcMapName $T10Svc)
        $status = { param([string] $Text, [string[]] $Names) Get-PgIdentStatus -Entries @(Get-PgIdentEntries -Lines @(Split-ConfLines -Text $Text)) -RequiredNames $Names }
        Check 'T10 empty ident is MISSING_ENTRY' (& $status $T10Empty $required) 'MISSING_ENTRY'
        Check 'T10 Veeam default ident: svc_veeam missing wins over the extra Administrator' (& $status $T10Veeam $required) 'MISSING_ENTRY'
        Check 'T10 pilot ident: Administrator is an extra entry' (& $status $T10Pilot $required) 'EXTRA_ENTRY'
        Check 'T10 a line in another map is ignored' (& $status $T10OtherMap $required) 'STANDARD'
        Check 'T10 svc_veeam mapped to another role is MISSING_ENTRY' (& $status $T10OtherRole $required) 'MISSING_ENTRY'
        $extraRole = $T10OtherMap + "`n" + 'veeam   "svc_veeam@VBR-PILOT01"   pg_native_admin'
        Check 'T10 an extra line to another role is EXTRA_ENTRY' (& $status $extraRole $required) 'EXTRA_ENTRY'
        $roleCase = 'veeam "SYSTEM@NT AUTHORITY" Postgres' + "`n" + 'veeam "svc_veeam@VBR-PILOT01" postgres'
        Check 'T10 the role name is case-sensitive' (& $status $roleCase $required) 'MISSING_ENTRY'
        $nameCase = 'veeam "system@nt authority" postgres' + "`n" + 'veeam SVC_VEEAM@vbr-pilot01 postgres'
        Check 'T10 system names compare case-insensitively' (& $status $nameCase $required) 'STANDARD'
        $twice = $T10OtherMap + "`n" + 'veeam "SYSTEM@NT AUTHORITY" postgres'
        Check 'T10 a required line twice is still STANDARD' (& $status $twice $required) 'STANDARD'
        $withService = @(Get-RequiredIdentNames -SvcMapName $T10Svc -ServiceAccountMapNames @('veeamsvc@CORP'))
        Check 'T10 a service account line is required' (& $status $T10OtherMap $withService) 'MISSING_ENTRY'
        $serviceLine = $T10OtherMap + "`n" + 'veeam "VEEAMSVC@corp" postgres'
        Check 'T10 a service account line in another case counts' (& $status $serviceLine $withService) 'STANDARD'
        Check 'T10 that service account line is extra when not required' (& $status $serviceLine $required) 'EXTRA_ENTRY'
        Check 'T10 a regex system user is an extra entry' (& $status ($T10OtherMap + "`n" + 'veeam /^(.*)@VBR-PILOT01$ postgres') $required) 'EXTRA_ENTRY'
        $hashEntries = @(@{ Map = 'veeam'; SystemUser = 'SYSTEM@NT AUTHORITY'; PgUser = 'postgres' }, @{ Map = 'veeam'; SystemUser = $T10Svc; PgUser = 'postgres' })
        Check 'T10 entries given as hashtables are read too' (Get-PgIdentStatus -Entries $hashEntries -RequiredNames $required) 'STANDARD'
    } catch {
        Check 'T10 status checks ran without an error' $_.Exception.Message ''
    }
}

# New-PgIdentText.
& {
    try {
        $required = @(Get-RequiredIdentNames -SvcMapName $T10Svc)
        $render = { param([string] $Text, [string[]] $Names, [string] $Eol) New-PgIdentText -Lines @(Split-ConfLines -Text $Text) -RequiredNames $Names -LineEnding $Eol -Stamp $T10Stamp }
        $statusOf = { param([string] $Text, [string[]] $Names) Get-PgIdentStatus -Entries @(Get-PgIdentEntries -Lines @(Split-ConfLines -Text $Text)) -RequiredNames $Names }

        $expectedPilot = @'
# MAPNAME       SYSTEM-USERNAME         PG-USERNAME
veeam   "SYSTEM@NT AUTHORITY"   postgres
# [VbrStandardise 20261012-101500] veeam   Administrator@VBR-PILOT01   postgres
veeam   "svc_veeam@VBR-PILOT01"   postgres
'@
        $out = & $render $T10Pilot $required "`r`n"
        Check 'T10 pilot ident renders exactly as expected (CRLF)' ($out -ceq (Join-ConfLines -Lines @(Split-ConfLines -Text $expectedPilot) -LineEnding "`r`n")) $true
        Check 'T10 rendered pilot ident is STANDARD' (& $statusOf $out $required) 'STANDARD'

        $expectedVeeam = @'
# MAPNAME       SYSTEM-USERNAME         PG-USERNAME
veeam   "SYSTEM@NT AUTHORITY"   postgres
# [VbrStandardise 20261012-101500] veeam   Administrator@DOMAIN   postgres
veeam   "svc_veeam@VBR-PILOT01"   postgres
'@
        $out = & $render $T10Veeam $required "`n"
        Check 'T10 Veeam default ident renders exactly as expected (LF)' ($out -ceq (Join-ConfLines -Lines @(Split-ConfLines -Text $expectedVeeam) -LineEnding "`n")) $true
        Check 'T10 rendered Veeam default ident is STANDARD' (& $statusOf $out $required) 'STANDARD'

        $emptyLines = @(Split-ConfLines -Text $T10Empty)
        $out = @(Split-ConfLines -Text (& $render $T10Empty $required "`r`n"))
        Check 'T10 empty ident keeps every comment line' (($out[0..($emptyLines.Count - 1)] -join '|') -ceq ($emptyLines -join '|')) $true
        Check 'T10 empty ident gets SYSTEM and svc_veeam appended' (($out[$emptyLines.Count..($out.Count - 1)]) -join '|') ('veeam   "SYSTEM@NT AUTHORITY"   postgres|veeam   "svc_veeam@VBR-PILOT01"   postgres')

        $out = & $render $T10OtherMap $required "`n"
        Check 'T10 a line in another map is kept unchanged' (@(Split-ConfLines -Text $out) -ccontains 'pgadmins   "jdoe@CORP"   pg_native_admin') $true
        Check 'T10 a Veeam (capital V) line is another map and kept unchanged' (@(Split-ConfLines -Text $out) -ccontains 'Veeam   "Administrator@VBR-PILOT01"   postgres') $true
        Check 'T10 a standard ident renders unchanged' ($out -ceq (Join-ConfLines -Lines @(Split-ConfLines -Text $T10OtherMap) -LineEnding "`n")) $true

        $out = @(Split-ConfLines -Text (& $render $T10OtherRole $required "`n"))
        Check 'T10 a veeam line to another role is commented out' ($out -ccontains ($T10Prefix + 'veeam   "svc_veeam@VBR-PILOT01"   pg_native_admin')) $true
        Check 'T10 ...and the svc_veeam line to postgres is appended' $out[$out.Count - 1] 'veeam   "svc_veeam@VBR-PILOT01"   postgres'
        Check 'T10 rendered other-role ident is STANDARD' (& $statusOf (Join-ConfLines -Lines $out -LineEnding "`n") $required) 'STANDARD'

        $withService = @(Get-RequiredIdentNames -SvcMapName $T10Svc -ServiceAccountMapNames @('veeamsvc@CORP', 'backupsvc@CORP'))
        $serviceText = $T10Pilot + "`n" + 'veeam   "VEEAMSVC@corp"   postgres'
        $out = @(Split-ConfLines -Text (& $render $serviceText $withService "`n"))
        Check 'T10 an existing service account line is kept as written' ($out -ccontains 'veeam   "VEEAMSVC@corp"   postgres') $true
        Check 'T10 a missing service account line is added once' (@($out | Where-Object { $_ -like '*backupsvc@CORP*' }).Count) 1
        Check 'T10 veeamsvc is not added a second time' (@($out | Where-Object { $_ -like '*veeamsvc@corp*' }).Count) 1
        Check 'T10 rendered service ident is STANDARD' (& $statusOf (Join-ConfLines -Lines $out -LineEnding "`n") $withService) 'STANDARD'

        # CP1252 and UTF-8 bytes in a comment and in a removed veeam line survive byte
        # for byte; CRLF is kept.
        $latin1 = [System.Text.Encoding]::GetEncoding(28591)
        $commentBytes = [byte[]]($latin1.GetBytes('# Caf') + [byte[]](0xE9, 0x20, 0x80) + $latin1.GetBytes(' UTF-8 ') + [byte[]](0xC3, 0xA9))
        $removedBytes = [byte[]]($latin1.GetBytes('veeam   "J') + [byte[]](0xFC) + $latin1.GetBytes('rgen@CORP"   postgres'))
        $fileBytes = [byte[]]($commentBytes + [byte[]](13, 10) + $latin1.GetBytes('veeam   "SYSTEM@NT AUTHORITY"   postgres') + [byte[]](13, 10) + $removedBytes + [byte[]](13, 10))
        $read = ConvertFrom-Latin1Bytes -Bytes $fileBytes
        $outBytes = ConvertTo-Latin1Bytes -Text (New-PgIdentText -Lines @(Split-ConfLines -Text $read) -RequiredNames $required -LineEnding "`r`n" -Stamp $T10Stamp)
        $hex = { param([byte[]] $B) '-' + [System.BitConverter]::ToString($B) + '-' }
        Check 'T10 a comment with CP1252 and UTF-8 bytes survives byte for byte' ((& $hex $outBytes).Contains((& $hex ([byte[]]($commentBytes + [byte[]](13, 10)))))) $true
        Check 'T10 a removed veeam line keeps its bytes after the ASCII prefix' ((& $hex $outBytes).Contains((& $hex ([byte[]]($latin1.GetBytes($T10Prefix) + $removedBytes + [byte[]](13, 10)))))) $true
        Check 'T10 the appended svc_veeam line ends the file with CRLF' ((& $hex $outBytes).EndsWith((& $hex ($latin1.GetBytes('veeam   "svc_veeam@VBR-PILOT01"   postgres' + "`r`n"))))) $true

        Throws 'T10 a required name that is not ASCII is refused' { New-PgIdentText -Lines @('# empty') -RequiredNames @('SYSTEM@NT AUTHORITY', ('J' + [char]0xFC + 'rgen@CORP')) -LineEnding "`n" -Stamp $T10Stamp }
        Throws 'T10 a required name with a double quote is refused' { New-PgIdentText -Lines @('# empty') -RequiredNames @('a"b@CORP') -LineEnding "`n" -Stamp $T10Stamp }
        Throws 'T10 a stamp that is not ASCII is refused' { New-PgIdentText -Lines @('# empty') -RequiredNames $required -LineEnding "`n" -Stamp ('2026' + [char]0xE9) }
        Check 'T10 a non-ASCII name already mapped to postgres is kept, not refused' ((New-PgIdentText -Lines @(('veeam "J' + [char]0xFC + 'rgen@CORP" postgres'), 'veeam "SYSTEM@NT AUTHORITY" postgres') -RequiredNames @('SYSTEM@NT AUTHORITY', ('J' + [char]0xFC + 'rgen@CORP')) -LineEnding "`n" -Stamp $T10Stamp).Contains([string][char]0xFC)) $true
    } catch {
        Check 'T10 render checks ran without an error' $_.Exception.Message ''
    }
}

# One decision, two readers. Get-PgIdentFindings is the only place that decides how a
# pg_ident.conf maps against the required names (which veeam lines stay, which are
# extra, which names are missing). Get-PgIdentStatus (the check) and New-PgIdentText
# (the render) both read it, so they cannot disagree.
# New-IdentNameSet and Get-PgIdentFindings.
& {
    try {
        $required = @(Get-RequiredIdentNames -SvcMapName $T10Svc)
        $entriesOf = { param([string] $Text) @(Get-PgIdentEntries -Lines @(Split-ConfLines -Text $Text)) }
        $findingsOf = { param([string] $Text, [string[]] $Names) Get-PgIdentFindings -Entries @(& $entriesOf $Text) -RequiredNames $Names }
        $show = { param($F) '{0}/{1}' -f ($F.ExtraLineIndexes -join '|'), ($F.MissingNames -join '|') }

        $set = New-IdentNameSet -Names @('SYSTEM@NT AUTHORITY', 'system@nt authority', '', $null, 'svc_veeam@VBR-PILOT01')
        Check 'T10 a name set arrives as a set, not an unrolled list' ($set -is [System.Collections.Generic.HashSet[string]]) $true
        Check 'T10 a name set drops duplicates in another case and empty names' $set.Count 2
        Check 'T10 a name set finds a name in another case' $set.Contains('Svc_Veeam@vbr-pilot01') $true
        Check 'T10 a name set never holds the empty name' $set.Contains('') $false
        $emptySet = New-IdentNameSet
        Check 'T10 a name set built from nothing is an empty set' (($emptySet -is [System.Collections.Generic.HashSet[string]]) -and $emptySet.Count -eq 0) $true

        Check 'T10 findings: pilot has Administrator (line 2) as extra, nothing missing' (& $show (& $findingsOf $T10Pilot $required)) '2/'
        Check 'T10 findings: Veeam default has Administrator extra and svc_veeam missing' (& $show (& $findingsOf $T10Veeam $required)) '2/svc_veeam@VBR-PILOT01'
        Check 'T10 findings: a comments-only file misses both names, in required order' (& $show (& $findingsOf $T10Empty $required)) '/SYSTEM@NT AUTHORITY|svc_veeam@VBR-PILOT01'
        Check 'T10 findings: another map is ignored' (& $show (& $findingsOf $T10OtherMap $required)) '/'
        Check 'T10 findings: svc_veeam to another role is extra and missing' (& $show (& $findingsOf $T10OtherRole $required)) '1/svc_veeam@VBR-PILOT01'
        Check 'T10 findings: a regex system user is extra' (& $show (& $findingsOf ($T10OtherMap + "`n" + 'veeam /^(.*)@VBR-PILOT01$ postgres') $required)) '4/'
        Check 'T10 findings: a required line twice is not extra' (& $show (& $findingsOf ($T10OtherMap + "`n" + 'veeam "SYSTEM@NT AUTHORITY" postgres') $required)) '/'
        Check 'T10 findings: no required names makes every veeam line extra' (& $show (& $findingsOf $T10Pilot @())) '1|2|3/'
        Check 'T10 findings: a required name given in two cases is missing once' (& $show (& $findingsOf $T10Empty @('SYSTEM@NT AUTHORITY', 'system@nt authority'))) '/SYSTEM@NT AUTHORITY'
        $hashEntries = @(@{ Map = 'veeam'; SystemUser = 'who@CORP'; PgUser = 'postgres' })
        Check 'T10 findings: an entry without LineIndex reports -1' (& $show (Get-PgIdentFindings -Entries $hashEntries -RequiredNames @('SYSTEM@NT AUTHORITY'))) '-1/SYSTEM@NT AUTHORITY'
    } catch {
        Check 'T10 findings checks ran without an error' $_.Exception.Message ''
    }
}

# The check and the render agree on every fixture, because both read the same findings.
& {
    try {
        $required = @(Get-RequiredIdentNames -SvcMapName $T10Svc)
        $withService = @(Get-RequiredIdentNames -SvcMapName $T10Svc -ServiceAccountMapNames @('veeamsvc@CORP'))
        $cases = @(
            @{ Name = 'comments only'; Text = $T10Empty; Names = $required },
            @{ Name = 'Veeam default'; Text = $T10Veeam; Names = $required },
            @{ Name = 'pilot'; Text = $T10Pilot; Names = $required },
            @{ Name = 'other map'; Text = $T10OtherMap; Names = $required },
            @{ Name = 'other role'; Text = $T10OtherRole; Names = $required },
            @{ Name = 'role case'; Text = ('veeam "SYSTEM@NT AUTHORITY" Postgres' + "`n" + 'veeam "svc_veeam@VBR-PILOT01" postgres'); Names = $required },
            @{ Name = 'name case'; Text = ('veeam "system@nt authority" postgres' + "`n" + 'veeam SVC_VEEAM@vbr-pilot01 postgres'); Names = $required },
            @{ Name = 'regex'; Text = ($T10OtherMap + "`n" + 'veeam /^(.*)@VBR-PILOT01$ postgres'); Names = $required },
            @{ Name = 'required twice'; Text = ($T10OtherMap + "`n" + 'veeam "SYSTEM@NT AUTHORITY" postgres'); Names = $required },
            @{ Name = 'service line, required'; Text = ($T10OtherMap + "`n" + 'veeam "VEEAMSVC@corp" postgres'); Names = $withService },
            @{ Name = 'service line, not required'; Text = ($T10OtherMap + "`n" + 'veeam "VEEAMSVC@corp" postgres'); Names = $required },
            @{ Name = 'short veeam line'; Text = ('veeam' + "`n" + $T10OtherMap); Names = $required },
            @{ Name = 'trailing comment'; Text = ('veeam "SYSTEM@NT AUTHORITY" postgres # keep' + "`n" + 'veeam "svc_veeam@VBR-PILOT01" postgres # keep'); Names = $required },
            @{ Name = 'no required names'; Text = $T10Pilot; Names = @() }
        )
        foreach ($case in $cases) {
            $caseName = $case.Name
            $lines = @(Split-ConfLines -Text $case.Text)
            $normal = Join-ConfLines -Lines $lines -LineEnding "`n"
            $entries = @(Get-PgIdentEntries -Lines $lines)
            $findings = Get-PgIdentFindings -Entries $entries -RequiredNames $case.Names
            $status = Get-PgIdentStatus -Entries $entries -RequiredNames $case.Names
            $out = New-PgIdentText -Lines $lines -RequiredNames $case.Names -LineEnding "`n" -Stamp $T10Stamp
            $outLines = @(Split-ConfLines -Text $out)
            $outStatus = Get-PgIdentStatus -Entries @(Get-PgIdentEntries -Lines $outLines) -RequiredNames $case.Names

            $expectedStatus = 'STANDARD'
            if ($findings.MissingNames.Count -gt 0) { $expectedStatus = 'MISSING_ENTRY' } elseif ($findings.ExtraLineIndexes.Count -gt 0) { $expectedStatus = 'EXTRA_ENTRY' }
            Check "T10 agreement ($caseName): the status follows the findings" $status $expectedStatus
            Check "T10 agreement ($caseName): the rendered text is STANDARD" $outStatus 'STANDARD'
            Check "T10 agreement ($caseName): the render changes the text exactly when the status is not STANDARD" (($out -ceq $normal) -eq ($status -ceq 'STANDARD')) $true
            Check "T10 agreement ($caseName): lines commented out = extra entries" (@($outLines | Where-Object { $_.StartsWith($T10Prefix) }).Count) $findings.ExtraLineIndexes.Count
            Check "T10 agreement ($caseName): lines appended = missing names" ($outLines.Count - $lines.Count) $findings.MissingNames.Count
        }
    } catch {
        Check 'T10 agreement checks ran without an error' $_.Exception.Message ''
    }
}

# The decision is written once: the check and the render call Get-PgIdentFindings and
# neither holds the veeam map or postgres role rule itself.
& {
    try {
        $t10Fn = @{}
        foreach ($t10Node in $ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $t10Fn[$t10Node.Name] = $t10Node }
        $t10Calls = { param([string] $FunctionName) @($t10Fn[$FunctionName].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() }) }
        $t10Strings = { param([string] $FunctionName) @($t10Fn[$FunctionName].FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value }) }
        Check 'T10 Get-PgIdentStatus takes its decision from Get-PgIdentFindings' ((& $t10Calls 'Get-PgIdentStatus') -contains 'Get-PgIdentFindings') $true
        Check 'T10 New-PgIdentText takes its decision from Get-PgIdentFindings' ((& $t10Calls 'New-PgIdentText') -contains 'Get-PgIdentFindings') $true
        Check 'T10 New-PgIdentText reads the entries through Get-PgIdentEntries, not its own token split' (((& $t10Calls 'New-PgIdentText') -contains 'Get-PgIdentEntries') -and -not ((& $t10Calls 'New-PgIdentText') -contains 'Split-ConfTokens')) $true
        Check 'T10 Get-PgIdentStatus holds no map or role rule of its own' (@((& $t10Strings 'Get-PgIdentStatus') | Where-Object { $_ -ceq 'veeam' -or $_ -ceq 'postgres' }).Count) 0
        Check 'T10 New-PgIdentText holds no map or role rule of its own' (@((& $t10Strings 'New-PgIdentText') | Where-Object { $_ -ceq 'veeam' -or $_ -ceq 'postgres' }).Count) 0
        Check 'T10 Get-PgIdentFindings holds the map rule once' (@((& $t10Strings 'Get-PgIdentFindings') | Where-Object { $_ -ceq 'veeam' }).Count) 1
        Check 'T10 Get-PgIdentFindings holds the role rule once' (@((& $t10Strings 'Get-PgIdentFindings') | Where-Object { $_ -ceq 'postgres' }).Count) 1
        Check 'T10 Get-RequiredIdentNames builds its set through New-IdentNameSet' ((& $t10Calls 'Get-RequiredIdentNames') -contains 'New-IdentNameSet') $true
    } catch {
        Check 'T10 single-decision checks ran without an error' $_.Exception.Message ''
    }
}
# ===================== RESULT =====================
foreach ($testFolder in @($script:TestFolders)) {
    Remove-Item -LiteralPath $testFolder -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($script:SkipCount -gt 0) { Write-Host "($script:SkipCount skipped)" }
Write-Host "RESULT: $script:PassCount passed, $script:FailCount failed"
if ($script:FailCount -gt 0) { exit 1 }
exit 0
