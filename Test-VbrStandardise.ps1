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
# ===================== RESULT =====================
foreach ($testFolder in @($script:TestFolders)) {
    Remove-Item -LiteralPath $testFolder -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($script:SkipCount -gt 0) { Write-Host "($script:SkipCount skipped)" }
Write-Host "RESULT: $script:PassCount passed, $script:FailCount failed"
if ($script:FailCount -gt 0) { exit 1 }
exit 0
