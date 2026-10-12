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
# ===================== RESULT =====================
foreach ($testFolder in @($script:TestFolders)) {
    Remove-Item -LiteralPath $testFolder -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($script:SkipCount -gt 0) { Write-Host "($script:SkipCount skipped)" }
Write-Host "RESULT: $script:PassCount passed, $script:FailCount failed"
if ($script:FailCount -gt 0) { exit 1 }
exit 0
