# VBR Standardise Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Invoke-VbrStandardise.ps1`, an RMM script that makes each Windows VBR server have a local admin `svc_veeam` account and a PostgreSQL configuration database that uses Windows (SSPI) authentication only.

**Architecture:** One self-contained PowerShell 5.1 script made of top-level functions plus a short main body at the end. A custom test harness (`Test-VbrStandardise.ps1`) parses the script, loads every top-level function without running the main body, and tests them with mocks, temp folders and a throwaway `HKCU:` registry key. Pure functions (parsing, rendering, decisions) are separated from functions that touch the system, so most logic is tested without a VBR server.

**Tech Stack:** Windows PowerShell 5.1 (Desktop, 64-bit), ADSI `WinNT://`, Microsoft.PowerShell.LocalAccounts, `psql.exe`, `reg.exe`, Win32 services, git.

**Spec:** `docs/superpowers/specs/2026-10-12-vbr-standardise-design.md` (read it before any task; section numbers below refer to it).

**Plan check (2026-10-12):** the script and test file were built from the code blocks of Tasks 1–18 alone, following each task's insertion instructions. Result: `RESULT: 1422 passed, 0 failed` under Windows PowerShell 5.1 and PowerShell 7.4, on an elevated prompt on English Windows 11 without PostgreSQL or VBR. Every task's "fail before" and "pass after" counts were measured the same way. On other machines some checks print `SKIP`; each task's Step 4 says which.

## Global Constraints

- Runtime: Windows PowerShell 5.1 Desktop edition, 64-bit process. The script must also PARSE under PowerShell 7 (the test file loads functions under `pwsh.exe`). No PowerShell 7-only syntax: no `?:` ternary, no `??`, no `?.`, no `&&`/`||` pipeline chains, no `-Parallel`.
- Every file starts with `Set-StrictMode -Version 2.0` and `$ErrorActionPreference = 'Stop'` (script) — the test file uses the same.
- All logic lives in top-level `function` definitions in `Invoke-VbrStandardise.ps1`. Functions get their inputs through parameters. If a function must read a script-scope variable, read it defensively: `Get-Variable -Name X -Scope Script -ValueOnly -ErrorAction SilentlyContinue`.
- New functions are inserted ABOVE the line `# ===================== MAIN =====================` in `Invoke-VbrStandardise.ps1`, inside the region named in the task.
- New tests are inserted ABOVE the line `# ===================== RESULT =====================` in `Test-VbrStandardise.ps1`, in a section headed `# --- Task N: <name> ---`.
- Settings (spec section 5), returned by `Get-DefaultConfig`: `ServiceAccountName='svc_veeam'`, `ServiceAccountDescription='Veeam maintenance account (PostgreSQL SSPI map)'`, `PasswordEnvVar='VEEAM_SVC_PASSWORD'`, `ServiceStopTimeoutSec=300`, `VbrConnectTimeoutSec=600`, `RollbackSettleSec=300`, `BusyPersistentHours=6`, `RetentionDays=30`.
- Exit codes (spec 6.2), returned by `Get-ExitCodeTable`: `OK=0`, `ACTION_NEEDED=5`, `RETRY=10`, `UNSUPPORTED=11`, `PREFLIGHT=20`, `ESCALATE=40`, `ESCALATE_NOW=50`.
- Issue codes: use exactly the names in spec 6.3. Do not invent new ones.
- Default WorkRoot: `C:\ProgramData\VeeamStandardise`. Mutex: `Global\VeeamPgUpdate`. Own marker: `<WorkRoot>\CHANGES-IN-PROGRESS.marker`. Last failure: `<WorkRoot>\last-failure.json`. Password env var: `VEEAM_SVC_PASSWORD`.
- Registry key: `HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication\DatabaseConfigurations\PostgreSql`. Values: `SqlHostName`, `SqlHostPort` (DWord), `SqlDatabaseName`, `SqlUserName`, `SqlSecuredPassword`, `PostgresUserForWindowsAuth`, `SqlLockInfo` (never changed).
- FORBIDDEN anywhere in the script (static tests in Task 18 enforce): `Stop-Service` with `-Force`, `Stop-Process`, `Get-LocalGroupMember`, `Read-Host`, `Out-File`, `Set-Content -Encoding UTF8`, `ConvertTo-SecureString` with a literal, `Invoke-Expression`. The password value must never reach `Write-Log`, `Write-Host`, the transcript, a file, or a native program's arguments.
- Config files (`pg_hba.conf`, `pg_ident.conf`) are read and written as bytes. Text work uses Latin-1 (code page 28591), which maps every byte to one char and back, so original bytes survive unchanged. New lines are ASCII only. Never write a BOM.
- Tests run from an elevated prompt in the project folder:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`
  Expected last line on success: `RESULT: <n> passed, 0 failed`. Exit code 0.
- Commits: imperative subject; body says what and why; end with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Every commit that changes the script also changes the test file.

## Shared contract (names, parameters, return shapes)

Every task implements exactly the functions listed for it here, with these names, parameters and return shapes. Later tasks rely on them. Return objects are `[pscustomobject]` unless it says hashtable.

**Additions made while writing the tasks (binding; each task's Produces block has the detail):**
- `Invoke-Native` returns `ExitCode = -1` and `Could not run <path>: <reason>` in StdErr when the program cannot start. `-StdinText` must be ASCII.
- `Get-PreflightContextIssue` declares its edition parameter as `[Alias('PSEdition')] [string] $Edition`, because `$PSEdition` is a read-only automatic variable. Callers still pass `-PSEdition`.
- Task 3 adds private helpers in region Preflight: `Test-PathTreeHasReparsePoint`, `Test-RegularTrustedFile`, `Test-ProtectedFolderAcl`, `Test-SafeWorkRootParent`, `New-ProtectedDirectory`.
- `Find-ChangeMarkers -UpdaterPaths`: element 0 counts whenever it exists; later elements count only when `Test-TrustedLegacyMarker` is true.
- `Complete-Run`: `-ExitCode` alone sets a minimum exit code; `-Detail` without `-Code` is a note appended to Detail; `$script:CompleteRunActive` guards against re-entry; the main body sets `$script:Report.LogPath`; WorkRoot comes from the script-scope `$WorkRoot`.
- `Get-PsqlFailureKind` and `Find-AuthErrors` match SQLSTATE `28000:` / `28P01:` only with the colon.
- Task 16 adds `Clear-PathFixedIssues -Ctx <hashtable> [-IncludePassword]` (region PathA): after a verified path it removes the drift issues that path fixed and updates `$Ctx.State` and `$script:Report`.
- `Invoke-PathA`, `Invoke-PathB` and `Invoke-PathBRollback` return `{ ExitCode; Code; Detail; Action }` (`Action = ''` means the default action).
- `Restore-PathAFiles` runs `Test-PgSspiLogin` and then `Test-PgConfigHealth` after the restore.
- Task 18 adds `Exit-IfConstrainedLanguage -Mode <string>` (region MainHelpers), called first in the main body.
- Extra script variables: `$script:CompleteRunActive`, `$script:TrapHandled`, `$script:Ctx` (the main body's `$Ctx`, read by the trap handler).
- Path B writes `services-before.json` to the run folder. The registry export covers the `DatabaseConfigurations\PostgreSql` key only.

### Test harness API (Task 1)
- `Check <name> <actual> <expected>` — compares `"$actual" -ceq "$expected"`; prints `  PASS  name` or `  FAIL  name  expected '<e>' got '<a>'`; counts.
- `Throws <name> <scriptblock>` — PASS if the block throws.
- `Skip <name> <reason>` — prints `  SKIP  name  (reason)`; not counted as fail.
- `$script:LogLines` — `System.Collections.ArrayList`; the harness redefines `Write-Log` to append `"[$Level] $Message"` here instead of printing.
- `New-TestFolder <tag>` — creates and returns `$env:TEMP\vbrstd-<tag>-<PID>-<n>`; all are removed at the end.
- `$ScriptText` — the full text of `Invoke-VbrStandardise.ps1`; `$ScriptAst` — its AST.

### Task 1 — core
- `Get-DefaultConfig` → hashtable (Global Constraints values).
- `Get-ExitCodeTable` → hashtable (Global Constraints values).
- `Write-Log -Message <string> [-Level <string> = 'INFO']` (levels `INFO|WARN|ERROR|OK|STEP`).
- `Format-ShortText -Text <string> [-MaxLength <int> = 900]` → string (whitespace collapsed, cut with `...`).
- `Invoke-Native -FilePath <string> [-Arguments <string[]>] [-StdinText <string>]` → `{ ExitCode:int; StdOut:string; StdErr:string }` (both trimmed). Never throws for a non-zero exit.
- `Get-RegValue -Path <string> -Name <string>` → value or `$null` (no error if key/value missing).
- `Get-CfgValue -Object <object> -Name <string> [-Default <object>]` → value (hashtable key or property), or Default.
- `ConvertFrom-JsonArrayText -Text <string>` → `object[]` (same result on 5.1 and 7).
- `Write-AtomicText -Path <string> -Text <string>` (UTF-8 without BOM, temp + replace).
- `Write-AtomicJson -Path <string> -Object <object>` (`ConvertTo-Json -Depth 8`, then `Write-AtomicText`).

### Task 2 — outcome and reporting
- `New-RunReport -Mode <string>` → `[ordered]` hashtable with keys in this order: `Computer, Timestamp, Mode, VbrVersion, PgMajor, SvcAccount, DbAuth, PgHba, PgIdent, PgPassword, Stage, Outcome, ExitCode, IssueCode, ActionRequired, Detail, LogPath`. Defaults: `Computer=$env:COMPUTERNAME`, `Timestamp` = `yyyy-MM-ddTHH:mm:ssK`, `Mode`, `Stage='UNTOUCHED'`, `ExitCode=''`, others `'UNKNOWN'` for status fields and `''` for text fields.
- `Add-RunIssue -Code <string> -ExitCode <int> [-Detail <string>] [-Action <string>]` → appends `{ Code; ExitCode; Detail; Action }` to `$script:Issues` (an `ArrayList`; created if missing).
- `Get-RmmActionForExitCode -ExitCode <int>` → default action text per code (0 → `None`).
- `Resolve-RunOutcome -Issues <object[]>` → `{ ExitCode:int; IssueCode:string; ActionRequired:string; Detail:string }`. Highest ExitCode wins; tie → earliest. Detail = every issue as `CODE: detail` joined by ` | `. No issues → `0`, `''`, `'None'`, `''`. ActionRequired = the winner's Action, else `Get-RmmActionForExitCode`.
- `Format-RmmSummary -Report <System.Collections.IDictionary>` → `string[]`: `=== RMM SUMMARY ===`, one line `Key=Value; Key=Value; ...` (all report keys, values through `Format-ShortText`), then `RMM ACTION: <ActionRequired>` unless it is `None`, then `RMM ISSUE: <IssueCode> | <Detail>` when IssueCode is set, then `===================`.
- `Get-TrapAction -Stage <string>` → `EXIT_UNHANDLED` (UNTOUCHED or unknown), `RESTORE_PATH_A` (PATH_A_WRITING), `NO_ROLLBACK` (PATH_A_DONE, VERIFIED), `ROLLBACK_PATH_B` (PATH_B_CHANGING).
- `Complete-Run [-ExitCode <int>] [-Code <string>] [-Detail <string>] [-Action <string>]` → does not return. If `-Code` given, calls `Add-RunIssue` first. Resolves `$script:Issues`, fills `$script:Report` (`Outcome` = `OK` when 0 else the IssueCode; `Stage` = `$script:Stage`), prints `Format-RmmSummary` with `Write-Host`, writes `<WorkRoot>\logs\last-result.json` when `$script:WorkRootReady` is `$true`, stops the transcript if `$script:TranscriptStarted`, releases `$script:RunLock` with `Exit-RunLock`, then `exit <code>`. All script variables read defensively.

### Task 3 — host preflight, work root, markers
- `Test-IsAdministrator` → bool.
- `Get-PreflightContextIssue -PSEdition <string> -IsAdmin <bool> -Is64BitOS <bool> -Is64BitProcess <bool> -LanguageMode <string>` → `$null` or `{ Code; ExitCode; Detail; Action }`. Order: `WRONG_POWERSHELL` (edition not `Desktop`), `NOT_ELEVATED`, `HOST_32BIT` (64-bit OS and 32-bit process), `CONSTRAINED_LANGUAGE` (not `FullLanguage`). All exit 20.
- `Enter-RunLock [-Name <string> = 'Global\VeeamPgUpdate']` → `[System.Threading.Mutex]` when acquired (an abandoned mutex counts as acquired), `$null` when another process holds it.
- `Exit-RunLock -Mutex <System.Threading.Mutex>` → releases and disposes; never throws.
- `Test-TrustedLegacyMarker -Path <string>` → bool (copy of the updater's trusted-owner and no-reparse-point test).
- `Find-ChangeMarkers -WorkRoot <string>` → `string[]` of existing marker files: `<WorkRoot>\CHANGES-IN-PROGRESS.marker`, `C:\ProgramData\VeeamPgUpdate\CHANGES-IN-PROGRESS.marker`, and `C:\temp\VeeamPgUpdate\CHANGES-IN-PROGRESS.marker` only if `Test-TrustedLegacyMarker` is true. Takes optional `-UpdaterPaths <string[]>` (default the two updater paths) so tests can point elsewhere.
- `Test-IsDomainController` → bool (`Win32_OperatingSystem.ProductType -eq 2`).
- `Initialize-WorkRoot -Path <string>` → `{ Ok:bool; Detail:string }`. Creates `<Path>`, `logs`, `runs`; applies an ACL of SYSTEM + Administrators full control only, inheritance off; rejects reparse points and untrusted owners (adapted from the updater's WorkRoot protection, with names changed to this script).
- `New-RunFolder -WorkRoot <string> -Stamp <string>` → path `<WorkRoot>\runs\<Stamp>` (created).
- `Write-ChangeMarker -WorkRoot <string> -RunDir <string> -PathName <string> -Stage <string>` (JSON via `Write-AtomicJson`: `RunDir, Path, Stage, Time`).
- `Remove-ChangeMarker -WorkRoot <string>` → bool.
- `Write-LastFailure -WorkRoot <string> -RunDir <string> -Reason <string>`; `Test-LastFailure -WorkRoot <string>` → bool.
- `Remove-OldRunData -WorkRoot <string> -RetentionDays <int>` (deletes `logs\VbrStandardise_*.log` and `runs\*` folders older than the limit; never the marker or last-failure file).

### Task 4 — VBR registry and products
- `Get-VbrInstall [-RootKey <string> = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication']` → `{ Installed:bool; CorePath:string; Version:string }`.
- `Test-Vb365Installed` → bool (service `Veeam.Archiver.Service` or file `C:\Program Files\Veeam\Backup365\Veeam.Archiver.Service.exe`).
- `Get-VbrDbConfig [-RootKey <string> = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication']` → `{ RootKey; KeyPath; ActiveConfiguration; HostName; Port:int|$null; DatabaseName; UserName; PasswordSet:bool; WindowsAuthRole; EntraIdHost; EntraIdPort; EntraIdPasswordSet:bool }`. Never returns password data.
- `Get-EnterpriseManagerDbConfig [-RootKey <string> = 'HKLM:\SOFTWARE\Veeam\Veeam Backup Reporting']` → `$null` when absent, else `{ ActiveConfiguration; HostName; Port; PasswordSet:bool }`.
- `Get-LocalHostNames` → `string[]` (computer name, FQDN, every local IP address).
- `Get-DbHostClass -HostName <string> -LocalNames <string[]>` → `LOOPBACK` (`localhost`, `127.0.0.1`, `::1`), `LOCAL` (in LocalNames, case-insensitive), `REMOTE`.
- `Get-RegistryAuthMode -UserName <string> -PasswordSet <bool>` → `WINDOWS` when UserName is empty/null and PasswordSet is false, else `NATIVE`.

### Task 5 — PostgreSQL discovery
- `Test-PgServiceExecutableMatchesBaseDir -PathName <string> -BaseDir <string>` → bool (copy).
- `Find-PgInstall [-InstallationsKey <string> = 'HKLM:\SOFTWARE\PostgreSQL\Installations'] [-Services <object[]>]` → `{ Ok:bool; Code:string; Detail:string; Version; Major:int; BaseDir; DataDir; ServiceName; Psql; HbaPath; IdentPath }`. Codes: `NO_PG_FOUND`, `MULTIPLE_PG`, `PG_NOT_RUNNING`. `-Services` (objects with `Name, State, PathName`) defaults to `Win32_Service` and lets tests inject.
- `ConvertFrom-PostmasterPid -Text <string>` → `{ Pid:int; DataDir:string; Port:int }` (line 1 PID, line 2 data dir, line 4 port).
- `Test-PostmasterLive -DataDir <string> -ExpectedPort <int>` → `{ Ok:bool; Detail:string }` (PID is a running `postgres.exe`, port matches).
- `Get-PgConfSetting -Lines <string[]> -Name <string>` → last active value (quotes removed) or `$null`.
- `Test-PgConfOverride -DataDir <string>` → `string[]` of overridden names among `hba_file`, `ident_file` (reads `postgresql.conf` and `postgresql.auto.conf`).
- `Select-ListeningLoopback -Listeners <object[]> -Port <int>` → `string[]` subset of `127.0.0.1`, `::1` (listener objects have `LocalAddress`, `LocalPort`; `0.0.0.0` counts as `127.0.0.1`, `::` counts as `::1`).
- `Get-ListeningLoopback -Port <int>` → wrapper over `Get-NetTCPConnection -State Listen`.

### Task 6 — Windows names
- `Get-NtAccountParts -Sid <System.Security.Principal.SecurityIdentifier>` → `{ Domain; Name }`.
- `ConvertTo-SspiMapName -Domain <string> -Name <string>` → `Name@Domain`.
- `Get-SspiMapNameFromSid -Sid <SecurityIdentifier>` → string.
- `Test-AsciiText -Text <string>` → bool (all chars 0x20–0x7E).
- `Get-SystemMapNames` → `{ English='SYSTEM@NT AUTHORITY'; Translated:string; IsAscii:bool }` (Translated from `S-1-5-18`).
- `Resolve-ServiceStartName -StartName <string> -ComputerName <string> [-Translator <scriptblock>]` → `{ Kind; MapName; Detail }`. Kind: `LOCALSYSTEM` (`LocalSystem`, `NT AUTHORITY\SYSTEM`, `.\LocalSystem`, empty), `UNSUPPORTED` (`NT AUTHORITY\NetworkService`, `NT AUTHORITY\LocalService`, any name ending `$`), `ACCOUNT` (resolved, MapName set), `UNRESOLVED` (translator threw). `.\x` becomes `<ComputerName>\x` before translation. The translator takes one string (`DOMAIN\x` or UPN) and returns `name@domain`; default: `NTAccount → SecurityIdentifier → Get-SspiMapNameFromSid`.
- `Get-VeeamServiceAccountNames [-Services <object[]>] [-ComputerName <string>] [-Translator <scriptblock>]` → `{ MapNames:string[]; Unresolved:string[] }` over services whose `Name` starts with `Veeam` (objects have `Name, StartName`; default from `Win32_Service`).

### Task 7 — svc_veeam account
- `Get-ServiceAccountInfo -Name <string>` → `{ Exists:bool; IsUser:bool; Sid:SecurityIdentifier; UserFlags:int; HasExpirationDate:bool; IsLocked:bool; PasswordExpired:bool; IsAdmin:bool; MapName:string }` (ADSI WinNT; `IsUser=$false` + `Exists=$true` when the name is a group).
- `Get-ServiceAccountStatus -Info <object>` → `{ Status; Codes:string[]; NeedsAdmin:bool; NeedsFlags:bool }`. Status precedence: `MISSING`, `NAME_IN_USE`, `NOT_ADMIN`, `FLAGS_DRIFT`, `DISABLED`, `LOCKED_OUT`, `EXPIRED`, `OK`. Codes holds every matching issue code (`SVC_ACCOUNT_MISSING`, `SVC_NAME_IN_USE`, `SVC_NOT_ADMIN`, `SVC_FLAGS_DRIFT`, `SVC_DISABLED`, `SVC_LOCKED_OUT`, `SVC_PASSWORD_EXPIRED`). Flags: `0x2` disabled, `0x10` locked, `0x40` cannot change password, `0x10000` password never expires; `HasExpirationDate=$true` is drift.
- `Test-AdministratorsMember -MemberSid <SecurityIdentifier>` → bool (ADSI `Members`, by SID, skips unreadable members).
- `Add-AdministratorsMember -UserSid <SecurityIdentifier> -UserName <string>` (treat "already a member" as success).
- `Read-ServiceAccountPassword -EnvVarName <string>` → `SecureString` or `$null`; removes the variable from the process environment at once.
- `ConvertTo-AccountIssueCode -ErrorRecord <System.Management.Automation.ErrorRecord>` → `SVC_PASSWORD_POLICY` (exception type name `InvalidPasswordException`), `SVC_NAME_IN_USE` (`NameInUseException`, `UserExistsException`), else `$null`.
- `New-ServiceAccount -Name <string> -Password <SecureString> -Description <string>` → `{ Created:bool; IssueCode:string }` (`New-LocalUser` with `-PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires`).
- `Set-ServiceAccountFlags -Name <string>` (`Set-LocalUser -PasswordNeverExpires $true -UserMayChangePassword $false -AccountNeverExpires`).
- `Invoke-ServiceAccountStep -Config <hashtable> -Apply <bool> -CreateRequested <bool>` → `{ Status; Info; BlocksDb:bool }`. Adds issues with `Add-RunIssue` (exit 5) per spec 7.2. `BlocksDb` is true when the account is missing, a group, or not an admin after this step.

### Task 8 — config file IO
- `ConvertFrom-Latin1Bytes -Bytes <byte[]>` → string; `ConvertTo-Latin1Bytes -Text <string>` → `byte[]`.
- `Get-Sha256Hex -Bytes <byte[]>` → lowercase hex string.
- `Read-ConfFile -Path <string>` → `{ Path; Bytes:byte[]; Text:string; LineEnding:string; HadBom:bool; Sddl:string }`. `Text` is Latin-1 of the bytes without the BOM. `LineEnding` is `"`r`n"` if the first line break is CRLF, else `"`n"`.
- `Split-ConfLines -Text <string>` → `string[]` (split on LF, remove a trailing CR from each line, no empty last element for a final line break).
- `Join-ConfLines -Lines <string[]> -LineEnding <string>` → string ending with one LineEnding.
- `Write-ConfFileAtomic -Path <string> -Bytes <byte[]> -ExpectedSddl <string>` → writes a temp file in the same folder, `[IO.File]::Replace(temp, Path, backup)` with a non-null backup path in the same folder, checks the file exists, SHA-256 matches and `(Get-Acl).Sddl` equals ExpectedSddl, deletes the backup. On any failure it puts the previous bytes back the same way and throws.
- `Backup-ConfFile -Path <string> -RunDir <string>` → path `<RunDir>\<filename>.before` holding the exact original bytes.
- `Restore-ConfFile -Path <string> -BackupPath <string> -ExpectedSddl <string>` → `Write-ConfFileAtomic` with the backup's bytes. Never `Move-Item`/`Copy-Item` into the data folder.

### Task 9 — pg_hba.conf
- `Split-ConfTokens -Line <string>` → `string[]` (whitespace-separated, double-quoted tokens kept whole with quotes removed, `#` outside quotes starts a comment).
- `Get-PgHbaRules -Lines <string[]>` → `object[]` of `{ LineIndex:int; Type; Database; User; Address; Method; Options }` for active lines. `local` lines have `Address=''`. An address followed by a netmask column becomes `address/prefix`.
- `Test-PgHbaHasInclude -Lines <string[]>` → bool (`include`, `include_if_exists`, `include_dir`, or any token starting `@`).
- `Get-StandardPgHbaLines` → the six lines of spec 7.3, fields separated by spaces.
- `Test-PgHbaStandard -Rules <object[]>` → bool (exactly the six standard rules in order, fields compared case-insensitively except Options compared as a set).
- `Get-NonLoopbackHbaRules -Rules <object[]>` → rules of type `host*` whose Address is not `127.0.0.1/32` or `::1/128`.
- `Get-HbaFirstMatch -Rules <object[]> -Database <string> -User <string> -Address <string>` → the first rule matching a TCP connection (`host`/`hostssl`/`hostnossl`; database `all`, `sameuser` treated as no-match unless equal, or exact case-sensitive name; user `all` or exact; address CIDR match for IPv4/IPv6) or `$null`.
- `New-PgHbaText -Lines <string[]> -LineEnding <string> -Stamp <string>` → string: header comment `# Standardised by Invoke-VbrStandardise.ps1 on <Stamp>`, the six standard lines, then every original line; original ACTIVE lines get the prefix `# [VbrStandardise <Stamp>] `; comment and blank lines stay as they are.

### Task 10 — pg_ident.conf
- `Get-PgIdentEntries -Lines <string[]>` → `object[]` of `{ LineIndex:int; Map; SystemUser; PgUser }` for active lines (quotes removed).
- `Get-RequiredIdentNames -SvcMapName <string> [-ServiceAccountMapNames <string[]>]` → `string[]`: `SYSTEM@NT AUTHORITY`, then SvcMapName, then service account names; duplicates removed case-insensitively.
- `Get-PgIdentStatus -Entries <object[]> -RequiredNames <string[]>` → `STANDARD`, `MISSING_ENTRY` (a required name has no `veeam` entry to `postgres`), or `EXTRA_ENTRY` (a `veeam` entry that is not required, or maps to another role). MISSING wins over EXTRA. Names compare case-insensitively.
- `New-PgIdentText -Lines <string[]> -RequiredNames <string[]> -LineEnding <string> -Stamp <string>` → string: non-`veeam` lines unchanged; `veeam` lines that are not required (or map to another role) get the prefix `# [VbrStandardise <Stamp>] `; missing required names appended as `veeam   "<name>"   postgres`.

### Task 11 — psql
- `Invoke-PgQuery -Psql <string> -Port <int> -HostAddress <string> -Database <string> -Sql <string> [-ViaStdin]` → `{ ExitCode; StdOut; StdErr }`. Args `-X -w -h <addr> -p <port> -U postgres -d <db> -t -A` plus `-c <sql>`, or `-f -` with the SQL as stdin when `-ViaStdin`. Sets `PGPASSFILE=nul`, `PGCONNECT_TIMEOUT=10`, clears `PGUSER PGHOST PGPASSWORD PGSERVICE PGSSLMODE` for the call and restores the old values in `finally`.
- `Get-PsqlFailureKind -StdErr <string>` → `AUTH` (`SSPI authentication failed`, `no pg_hba.conf entry`, `no match in usermap`, `password authentication failed`, `no password supplied`, `28000`, `28P01`), `CONNECT` (`Connection refused`, `could not connect`, `timeout expired`, `10061`), else `OTHER`.
- `Test-PgSspiLogin -Psql <string> -Port <int> -Addresses <string[]> -Database <string>` → `{ Passed:bool; Results:object[] }` (each `{ Address; ExitCode; Kind; StdErr }`; Kind `OK` on success). Passed only if every address returns `1`.
- `ConvertTo-ComparablePath -Path <string>` → full path with `\`, no trailing `\`, lower case; `Test-SamePath -Left <string> -Right <string>` → bool.
- `Test-PgConfigHealth -Psql <string> -Port <int> -Address <string> -Database <string> -Major <int> -HbaPath <string> -IdentPath <string>` → `{ Ok:bool; Detail:string }` (pg_hba_file_rules errors = 0; on Major ≥ 15 pg_ident_file_mappings errors = 0; `SHOW hba_file`/`SHOW ident_file` match).
- `Get-PgLiveState -Psql <string> -Port <int> -Address <string> -Database <string>` → `{ Ok:bool; PasswordSet:bool; Backends:object[] }` (backends: `{ Pid; UseName; DatName; ClientAddr; BackendStartUtc:DateTime }` for `backend_type='client backend' AND pid <> pg_backend_pid()`; via `json_agg` + `ConvertFrom-JsonArrayText`).
- `Get-OtherPasswordRoles -Psql <string> -Port <int> -Address <string> -Database <string>` → `string[]` (login roles other than `postgres` with a password; booleans only, never hashes).
- `Clear-PostgresPassword -Psql <string> -Port <int> -Address <string> -Database <string>` → `{ Ok:bool; Detail:string }` (`ALTER ROLE postgres PASSWORD NULL;` through `-ViaStdin`, then re-check).

### Task 12 — live state and blockers
- `Test-VbrBackendsOk -Backends <object[]> -Database <string>` → bool (every backend whose DatName equals Database case-insensitively has UseName `postgres` and ClientAddr `127.0.0.1` or `::1`).
- `Get-DbAuthState -RegistryAuth <string> -SspiPassed <bool> -FirstMatchOk <bool> -VbrBackendsOk <bool>` → `NATIVE` (registry NATIVE), `WINDOWS` (registry WINDOWS and all three true), else `UNKNOWN`.
- `Select-RemoteClients -Connections <object[]> -Port <int>` → `string[]` remote addresses (objects have `LocalPort, RemoteAddress, State`; only `Established`; loopback excluded).
- `Get-EstablishedRemoteClients -Port <int>` → wrapper over `Get-NetTCPConnection`.
- `Get-ConsumerIssues -DbConfig <object> -EmConfig <object> -Backends <object[]> -RemoteClients <string[]> -LocalNames <string[]>` → `object[]` of `{ Code; Detail; Action }` with codes `PG_PASSWORD_CONSUMER` / `PG_REMOTE_CONSUMER` per spec 7.5. `-Backends` may be `$null` (no SSPI yet).

### Task 13 — idle gate and services
- `Get-BusyVeeamWork -Processes <object[]> -Now <DateTime> -PersistentHours <int>` → `{ Busy:bool; Persistent:bool; Names:string[] }` (objects have `Name, StartTime`; names compare without `.exe`: `Veeam.Backup.Manager`, `VeeamAgent`, `Veeam*Explorer*`).
- `Get-VeeamServiceSnapshot` → `object[]` of `{ Name; Status; StartType; DependsOn:string[]; Dependents:string[] }` for services named `Veeam*`.
- `Get-StopSet -Snapshot <object[]>` → `string[]` running services in stop order (alphabetical, any `*Management*Agent*` last).
- `Get-ExternalDependents -StopSet <string[]> -AllServices <object[]>` → `string[]` running services NOT in StopSet that depend (directly) on one in StopSet (objects have `Name, Status, DependsOn`).
- `Get-StartOrder -Snapshot <object[]> -Names <string[]>` → `string[]` (dependencies first; ties alphabetical).
- `Stop-ServicesBounded -Names <string[]> -TimeoutSec <int>` → `{ Ok:bool; Stopped:string[]; NotStopped:string[] }` (`Stop-Service -NoWait`, poll every 2 s).
- `Start-ServicesBounded -Names <string[]> -TimeoutSec <int>` → `{ Ok:bool; Started:string[]; NotStarted:string[] }` (`ServiceController.Start()` + `WaitForStatus` with the remaining time).
- `Test-ServiceStaysRunning -Name <string> -Seconds <int>` → bool (polls every 5 s).

### Task 14 — registry switch
- `Get-RegistryValueSnapshot -KeyPath <string> -Names <string[]>` → hashtable name → `{ Exists:bool; Kind:string; Data }`.
- `ConvertTo-RegExePath -KeyPath <string>` → e.g. `HKLM\SOFTWARE\...` from `HKLM:\SOFTWARE\...` (and `HKCU:` for tests).
- `Save-RegistryBackup -KeyPath <string> -ExportKeyPath <string> -RunDir <string> -Snapshot <hashtable>` → `{ JsonPath; RegPath }`; writes `registry-before.json`, runs `reg.exe export <ExportKeyPath> <RunDir>\vbr-key.reg /y`, throws if the export is missing or empty.
- `Get-RegistryTargets -DbConfig <object> -Addresses <string[]>` → `[ordered]` hashtable name → string: `SqlUserName=''`, `SqlSecuredPassword=''`, `PostgresUserForWindowsAuth='postgres'` (only if not already `postgres`), `SqlHostName` (only if not loopback: `127.0.0.1`, or `::1` if only `::1` listens).
- `Set-RegistryTargets -KeyPath <string> -Targets <System.Collections.IDictionary>` → writes each as `String`, reads back, throws on mismatch.
- `Restore-RegistrySnapshot -KeyPath <string> -Snapshot <hashtable> [-RegExportPath <string>]` → bool (spec 7.6 rollback step 3).

### Task 15 — VBR connect check
- `Get-FileLength -Path <string>` → `[long]` (0 when missing).
- `Read-LogTail -Path <string> -FromOffset <long>` → `string[]` lines written after the offset (whole file if it is now shorter than the offset; shared read so Veeam can keep writing).
- `Find-AuthErrors -Lines <string[]>` → `string[]` lines matching `SSPI authentication failed|no match in usermap|password authentication failed|no pg_hba.conf entry|28000|28P01`.
- `Test-VbrConnectEvidence -Backends <object[]> -SinceUtc <DateTime> -Database <string>` → bool (spec 7.13 backend rule).
- `Wait-VbrDbConnected -Psql <string> -Port <int> -Address <string> -Database <string> -SinceUtc <DateTime> -TimeoutSec <int> -LogPath <string> -LogOffset <long> [-PollSec <int> = 10] [-ServiceName <string> = 'VeeamBackupSvc']` → `{ Ok:bool; Detail:string }`. Fails at once if auth errors appear.

### Task 16 — Path A
- `Invoke-PathA -Ctx <hashtable>` → `{ ExitCode:int; Code:string; Detail:string }`. Sets `$script:Stage`.
- `Restore-PathAFiles -Ctx <hashtable>` → bool (restore both files from `$Ctx.HbaBackupPath`/`$Ctx.IdentBackupPath`, then `Test-PgSspiLogin`).

### Task 17 — Path B
- `Invoke-PathB -Ctx <hashtable>` → `{ ExitCode:int; Code:string; Detail:string }`. Sets `$script:Stage`.
- `Invoke-PathBRollback -Ctx <hashtable> -Reason <string>` → `{ ExitCode:int; Code:string; Detail:string }` (40 or 50).

### Task 18 — main body
- `Get-AuditState -Ctx <hashtable>` (fills `$Ctx.State` and the report fields; adds drift and blocker issues).
- `Select-ApplyPath -Ctx <hashtable>` → `NONE`, `A`, `B`, or `BLOCKED`.
- `Invoke-TrapHandler -ErrorRecord <System.Management.Automation.ErrorRecord>` (uses `Get-TrapAction`, then `Complete-Run`).
- The main body below `# ===================== MAIN =====================`.

### `$Ctx` keys (hashtable built by the main body; flows read these)
`Config` (Get-DefaultConfig), `WorkRoot`, `Stamp` (`yyyyMMdd-HHmmss`), `RunDir`, `Apply`, `CreateRequested`, `Vbr`, `Db` (Get-VbrDbConfig), `Em`, `LocalNames`, `Pg` (Find-PgInstall result plus `Port`), `Addresses` (listening loopback `string[]`), `SystemNames`, `Account` (Invoke-ServiceAccountStep result), `ServiceAccounts` (Get-VeeamServiceAccountNames result), `RequiredIdentNames`, `Hba` (Read-ConfFile), `HbaLines`, `HbaRules`, `Ident` (Read-ConfFile), `IdentLines`, `IdentEntries`, `State` (hashtable: `RegistryAuth`, `SspiPassed`, `DbAuth`, `PgHba`, `PgIdent`, `PgPassword`, `Backends`), `HbaBackupPath`, `IdentBackupPath`, `Snapshot` (services), `StopSet`, `Stopped` (`string[]` stopped by this run), `RegSnapshot`, `RegBackup`, `StartUtc`, `LogOffset`, `PasswordCleared` (bool).

---

### Task 1: Project scaffold, test harness and core helpers

**Files:**
- Create: `Invoke-VbrStandardise.ps1` (help, parameters, the 18 empty regions, the MAIN line and a temporary main body; this task's functions go in region Core)
- Create: `Test-VbrStandardise.ps1`
- Create: the git repository in the project folder

**Interfaces:**
- Consumes: none (first task).
- Produces: `Get-DefaultConfig`, `Get-ExitCodeTable`, `Write-Log`, `Format-ShortText`, `Invoke-Native`, `Get-RegValue`, `Get-CfgValue`, `ConvertFrom-JsonArrayText`, `Write-AtomicText`, `Write-AtomicJson`. Test harness API: `Check`, `Throws`, `Skip`, `New-TestFolder`, `$script:LogLines` with the `Write-Log` override, `$ScriptText`, `$ScriptAst` (and `$ScriptPath`).

Notes for every later task (the harness behaves like this):
- The harness parses `Invoke-VbrStandardise.ps1`, stops with a `FATAL:` line and exit 1 on a missing file or a parse error, and dot-sources every top-level function at script scope. The main body never runs.
- The harness functions are defined after the script's functions, so the harness `Write-Log` (records `"[$Level] $Message"` in `$script:LogLines`) replaces the real one. To test the real `Write-Log`, load its text from `$ScriptAst` into a `& { }` child scope, as the Task 1 tests do.
- A script-level `trap` turns any error that escapes a test statement into one `  FAIL  UNHANDLED  <message>` line and continues with the next statement. A missing function therefore shows as a FAIL, not a crash, and the run always reaches the RESULT line.
- Every test section shares the script scope: prefix test variables with the task number (`$t1Name`, `$t2Name`).
- `Invoke-VbrStandardise.ps1` must stay ASCII only (a Task 1 check enforces it). Build non-ASCII test data from `[char]` codes or byte arrays.
- `Invoke-Native` returns `ExitCode = -1` and the reason in `StdErr` when the program cannot be started. It never throws.

- [ ] **Step 1: Initialise the repository**

Run in the project folder (the folder that holds `docs\`):

```powershell
git init -b main
git status --short
```

Expected: `Initialized empty Git repository in <project folder>/.git/`, then `?? docs/`.

- [ ] **Step 2: Write the failing tests**

Create `Test-VbrStandardise.ps1` with exactly this content. It holds the harness, the Task 1 section and the RESULT section. Later tasks insert their sections just above the line `# ===================== RESULT =====================`.

```powershell
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

# ===================== RESULT =====================
foreach ($testFolder in @($script:TestFolders)) {
    Remove-Item -LiteralPath $testFolder -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($script:SkipCount -gt 0) { Write-Host "($script:SkipCount skipped)" }
Write-Host "RESULT: $script:PassCount passed, $script:FailCount failed"
if ($script:FailCount -gt 0) { exit 1 }
exit 0
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: one line `FATAL: <project folder>\Invoke-VbrStandardise.ps1 not found.` and exit code 1 (`$LASTEXITCODE`), because the script does not exist yet.

- [ ] **Step 4: Create the script skeleton**

Create `Invoke-VbrStandardise.ps1` with exactly this content. Keep the file ASCII only. Every later task inserts its functions just above `#endregion <Region>` of its region. Task 18 replaces everything below the MAIN line.

```powershell
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
#endregion Core

#region Outcome
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
```

- [ ] **Step 5: Run the tests again to verify the helper checks fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: the 24 skeleton and harness checks PASS (`T1 parameters are Apply, CreateServiceAccount, WorkRoot` through `T1 New-TestFolder name`). Every helper check FAILS, starting with `  FAIL  UNHANDLED  The term 'Get-DefaultConfig' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again.` and including `  FAIL  T1 script defines Write-Log  expected '1' got '0'`. The last line is `RESULT: 24 passed, 80 failed` and the exit code is 1.

- [ ] **Step 6: Implement**

In `Invoke-VbrStandardise.ps1`, insert this code between `#region Core` and `#endregion Core` (just above `#endregion Core`). The settings banner goes first, so the settings sit at the top of the script.

```powershell
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
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: 97 passed, 0 failed`, exit code 0.

Also check the temporary main body:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-VbrStandardise.ps1
$LASTEXITCODE
```

Expected: `20`. If PowerShell 7 is installed, `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1` must also end with `RESULT: 97 passed, 0 failed`, which proves that the script parses and its functions load under PowerShell 7.

- [ ] **Step 8: Commit**

```powershell
git add docs Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add script skeleton, test harness and core helpers" -m "Invoke-VbrStandardise.ps1 gets its help, parameters, the 18 regions and a temporary main body. Test-VbrStandardise.ps1 loads the script's functions through the AST without running the main body. The core helpers (settings, exit codes, logging, native calls, registry and property reads, JSON parsing, atomic UTF-8 writes without a BOM) are what every later task builds on." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git log --oneline -1
```

Expected: one commit, `Add script skeleton, test harness and core helpers`.

---

### Task 2: Run outcome, RMM summary and Complete-Run

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region Outcome)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Format-ShortText`, `Get-CfgValue`, `Write-Log`, `Write-AtomicJson` (Task 1). `Exit-RunLock` (Task 3): `Complete-Run` calls it inside `try`/`catch`, so this task works before Task 3 exists, and the tests use a stand-in.
- Produces: `New-RunReport`, `Add-RunIssue`, `Get-RmmActionForExitCode`, `Resolve-RunOutcome`, `Format-RmmSummary`, `Get-TrapAction`, `Complete-Run`.

Notes for later tasks:
- `Complete-Run` reads these script variables, each one defensively (a missing variable is never an error): `$script:Issues`, `$script:Report`, `$script:Stage`, `$WorkRoot` (the script parameter: the main body must keep the normalised WorkRoot path in it), `$script:WorkRootReady`, `$script:TranscriptStarted` and `$script:RunLock`. It sets `$script:CompleteRunActive` as a re-entry guard: a second call (for example from the trap after an error inside `Complete-Run`) exits at once with its own `-ExitCode`.
- `Complete-Run` does not fill `LogPath`. The main body sets `$script:Report.LogPath` when it starts the transcript.
- `-ExitCode` without `-Code` raises the exit code to at least that value, with the default action for it. With `-Code`, pass `-ExitCode` too.
- `-Detail` without `-Code` is a note, not an issue: it is added to the end of `Detail` (after ` | ` when there are issues) and changes neither the exit code nor `IssueCode`. The main body (Task 18) uses it for the notes of a successful path (spec 7.5: the `pg_hba.conf` lines that were commented out; spec 7.6 Path B step 13: the roles that can no longer log in). Task 18 tests it in a child process.
- In `Resolve-RunOutcome` an issue with an empty Detail appears in `Detail` as just its code.
- Tests that need `Complete-Run` must run it in a child process (it calls `exit`), or redefine it in a `& { }` child scope.

- [ ] **Step 1: Write the failing tests**

In `Test-VbrStandardise.ps1`, insert this section just above the line `# ===================== RESULT =====================`. The `Complete-Run` checks write a driver script into a test folder. The driver holds the real function texts from `$ScriptAst` and a stand-in `Exit-RunLock`, and runs in a child `powershell.exe` once per scenario.

```powershell
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: every Task 1 check still PASSES, and no `T2` check passes. The first Task 2 failure is `  FAIL  UNHANDLED  The term 'New-RunReport' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again.`. The driver checks fail as well, for example `  FAIL  T2 driver functions exist in the script  expected '' got 'New-RunReport,Add-RunIssue,Get-RmmActionForExitCode,Resolve-RunOutcome,Format-RmmSummary,Complete-Run'` and `  FAIL  T2 issues: exit code is the highest issue  expected '10' got '1'`. The last line is `RESULT: 97 passed, 104 failed` and the exit code is 1.

- [ ] **Step 3: Implement**

In `Invoke-VbrStandardise.ps1`, insert this code between `#region Outcome` and `#endregion Outcome` (just above `#endregion Outcome`).

```powershell
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: 195 passed, 0 failed`, exit code 0. The three child runs add a few seconds.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add run outcome, RMM summary and Complete-Run" -m "Every check records its issues in one list. Complete-Run picks the highest exit code (ties go to the earliest issue), fills the report, prints the RMM summary block, writes last-result.json only when the WorkRoot is ready, stops the transcript, releases the run lock and exits. Get-TrapAction maps each stage to the trap's action from spec 7.6." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git log --oneline -1
```

Expected: `Add run outcome, RMM summary and Complete-Run`.

---

### Task 3: Host preflight, work root, lock and markers

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region Preflight)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Write-Log`, `Write-AtomicJson`, `Get-CfgValue` (Task 1).
- Produces: `Test-IsAdministrator`, `Get-PreflightContextIssue`, `Enter-RunLock`, `Exit-RunLock`, `Test-TrustedLegacyMarker`, `Find-ChangeMarkers`, `Test-IsDomainController`, `Initialize-WorkRoot`, `New-RunFolder`, `Write-ChangeMarker`, `Remove-ChangeMarker`, `Write-LastFailure`, `Test-LastFailure`, `Remove-OldRunData`.
- Produces (private helpers, not in the shared contract, used only inside region Preflight; copied from the updater's WorkRoot protection with the updater-specific names changed): `Test-PathTreeHasReparsePoint`, `Test-RegularTrustedFile`, `Test-ProtectedFolderAcl`, `Test-SafeWorkRootParent`, `New-ProtectedDirectory`.

Read before you start (spec 5, 7.1 steps 1-6, 7.6, 7.7):
- `$PSEdition` is a read-only automatic variable. A parameter with that name fails at bind time ("Cannot overwrite variable PSEdition because it is read-only or constant"). `Get-PreflightContextIssue` therefore names its parameter `$Edition` and carries `[Alias('PSEdition')]`, so callers still pass `-PSEdition` as the contract says.
- `Initialize-WorkRoot` never changes the ACL of a folder that already exists. It creates a missing WorkRoot with the protected ACL in one native call (staging name, then rename). It accepts an existing folder only when the ACL is exactly SYSTEM + Administrators (owner Administrators, inheritance off) and the folder is empty or holds this script's sentinel file `.vbr-standardise` with the exact sentinel text. Anything else gives `Ok=$false` and a `Detail` that Task 18 reports as `WORKROOT_UNSAFE`.
- `Find-ChangeMarkers -UpdaterPaths`: element 0 is the updater's current marker and counts whenever it exists. Every later element is a legacy marker in a user-writable folder and counts only when `Test-TrustedLegacyMarker` accepts it.
- `Remove-OldRunData` keeps every run folder while this script's marker exists, and keeps the run folder named in `last-failure.json`, because a person needs them to recover.
- Main-body use (Task 18), in spec 7.1 order: `$script:RunLock = Enter-RunLock` first (`$null` gives exit 10 `CONCURRENT_RUN` and nothing else is checked); then `Get-PreflightContextIssue -PSEdition $PSVersionTable.PSEdition -IsAdmin (Test-IsAdministrator) -Is64BitOS ([Environment]::Is64BitOperatingSystem) -Is64BitProcess ([Environment]::Is64BitProcess) -LanguageMode "$($ExecutionContext.SessionState.LanguageMode)"`; then `Initialize-WorkRoot` before the transcript starts (`Ok=$false` gives exit 20 `WORKROOT_UNSAFE` with its `Detail`); then `@(Find-ChangeMarkers -WorkRoot $WorkRoot)` (any path gives exit 50 `MARKER_PRESENT` with the paths in `Detail`); then `Test-IsDomainController` (exit 11 `DOMAIN_CONTROLLER`).
- Test fixtures: the run-lock tests use a `Local\VbrStdTest-<PID>` mutex (no elevation needed, no clash with a real updater run) and check the `Global\VeeamPgUpdate` default through the AST. The `Initialize-WorkRoot` creation tests run only when elevated, and mock `Test-SafeWorkRootParent` inside a child scope: on some machines other accounts have Modify rights on the `%TEMP%` folder chain, so a `%TEMP%` parent can never pass the real check. The real check is tested read-only against `C:\ProgramData`, the parent of the default WorkRoot, and against a folder that grants Everyone full control.

- [ ] **Step 1: Write the failing tests**

Insert this block into `Test-VbrStandardise.ps1` directly above the line `# ===================== RESULT =====================`.

```powershell
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

# Test-SafeWorkRootParent on real folders (read only), and an unsafe parent
Check 'Test-SafeWorkRootParent: C:\ProgramData (parent of the default WorkRoot) is safe' (Test-SafeWorkRootParent -Path 'C:\ProgramData') 'True'
$t3Unsafe = New-TestFolder 'unsafe'
$t3Acl = Get-Acl -LiteralPath $t3Unsafe
$t3Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl -LiteralPath $t3Unsafe -AclObject $t3Acl
Check 'Test-SafeWorkRootParent: folder anyone can delete from is unsafe' (Test-SafeWorkRootParent -Path $t3Unsafe) 'False'
$t3R = Initialize-WorkRoot -Path (Join-Path $t3Unsafe 'root')
Check 'Initialize-WorkRoot: unsafe parent is refused' $t3R.Ok 'False'
Check 'Initialize-WorkRoot: nothing is created under an unsafe parent' (Test-Path -LiteralPath (Join-Path $t3Unsafe 'root')) 'False'

# Initialize-WorkRoot ACL work and the trusted legacy marker (elevation needed).
# The parent check is mocked here: it is tested above on C:\ProgramData, and on
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: FAIL. The harness `trap` turns each failing Task 3 statement into a `FAIL  UNHANDLED` line, starting with `  FAIL  UNHANDLED  The term 'Test-IsAdministrator' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again.` The same message follows for `Get-PreflightContextIssue`, `Enter-RunLock`, `Test-IsDomainController`, `Initialize-WorkRoot`, `Test-SafeWorkRootParent`, `Find-ChangeMarkers`, `New-RunFolder`, `Write-ChangeMarker`, `Remove-ChangeMarker`, `Test-TrustedLegacyMarker`, `Write-LastFailure`, `Test-LastFailure` and `Remove-OldRunData`, with follow-on lines such as `  FAIL  UNHANDLED  The variable '$t3I' cannot be retrieved because it has not been set.` With the Task 1 and Task 2 sections as written, the last line is `RESULT: 207 passed, 95 failed` (195 earlier checks, plus 12 Task 3 checks that also hold without the code, such as the two `Throws` checks), and the exit code is 1.

- [ ] **Step 3: Implement**

Insert the three blocks below into `Invoke-VbrStandardise.ps1`, in this order, directly above the line `#endregion Preflight`.

Block 1, host context, run lock and domain controller check:

```powershell
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
```

Block 2, WorkRoot trust boundary and the legacy marker test:

```powershell
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
```

Block 3, markers, run folders, last failure and retention:

```powershell
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected on an elevated prompt: `RESULT: 289 passed, 0 failed` (the Task 2 total of 195 plus 94 Task 3 checks) and exit code 0. Without elevation the 20 ACL checks are replaced by one `  SKIP  Initialize-WorkRoot ACL and trusted legacy marker tests  (not elevated)` line, the summary shows `(1 skipped)` and the line reads `RESULT: 269 passed, 0 failed`; always run elevated before committing. If PowerShell 7 is installed, `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1` gives the same RESULT line.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add host preflight, WorkRoot protection, run lock and markers" -m "Adds the spec 7.1 context checks, the shared Global\VeeamPgUpdate run lock, the WorkRoot trust checks adapted from the updater, the change and last-failure markers and retention, so later tasks can stop on an unsafe host before any change." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: VBR registry, products and host class

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region Vbr)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Get-RegValue` (Task 1).
- Produces: `Get-VbrInstall`, `Test-Vb365Installed`, `Get-VbrDbConfig`, `Get-EnterpriseManagerDbConfig`, `Get-LocalHostNames`, `Get-DbHostClass`, `Get-RegistryAuthMode`.

Read before you start (spec 7.1 steps 7-10, 7.5, 9):
- Registry layout. The root key holds `CorePath` and the Entra ID values `EntraIdSqlHostName`, `EntraIdSqlHostPort`, `EntraIdSqlPassword`. `<root>\DatabaseConfigurations` holds `SqlActiveConfiguration`. `<root>\DatabaseConfigurations\PostgreSql` holds `SqlHostName`, `SqlHostPort` (DWord), `SqlDatabaseName`, `SqlUserName`, `SqlSecuredPassword`, `PostgresUserForWindowsAuth`. Enterprise Manager uses the same layout under `HKLM:\SOFTWARE\Veeam\Veeam Backup Reporting`.
- Password values (`SqlSecuredPassword`, `EntraIdSqlPassword`) are reduced to a bool in the same expression that reads them. No function returns, stores or logs their data.
- Missing text values come back as `''`. `Port` and `EntraIdPort` are `[int]` in 1-65535, otherwise `$null` (absent, text or out of range). `Get-EnterpriseManagerDbConfig` returns `$null` when `<root>\DatabaseConfigurations` does not exist.
- `Get-VbrInstall` uses the updater's test: VBR is installed when the `CorePath` folder exists. Version is the ProductVersion of `Veeam.Backup.Service.exe`, then `Packages\VeeamDeploymentDll.dll`, else `Unknown`.
- `Get-DbHostClass` trims spaces, `[` `]` and a trailing `.`, and compares IPv6 text in canonical form. An empty host is not proven local, so it is `REMOTE` (fail closed: Task 18 then exits 11 `REMOTE_DB`).
- `Get-LocalHostNames` takes addresses only from the local network interfaces, never from DNS answers, because a stale DNS record can name another server. DNS is used for names (FQDN, aliases) only.
- Main-body use (Task 18), spec 7.1 steps 7-10: `(Get-VbrInstall).Installed` false gives exit 20 `VBR_NOT_FOUND`; `(Get-VbrDbConfig).ActiveConfiguration -ine 'PostgreSql'` gives exit 11 `VBR_DB_NOT_POSTGRES`; `Test-Vb365Installed` gives exit 11 `STACKED_VBR_VB365`; `Get-DbHostClass -HostName $db.HostName -LocalNames (Get-LocalHostNames)` gives `REMOTE` (exit 11 `REMOTE_DB`), `LOCAL` (drift `DB_HOST_NOT_LOCAL`) or `LOOPBACK`; a `WindowsAuthRole` that is not empty and not `postgres` is drift `DB_WINDOWS_ROLE_NOT_POSTGRES`; `Get-RegistryAuthMode -UserName $db.UserName -PasswordSet $db.PasswordSet` is the registry part of `DbAuth`.
- Tests build a throwaway `HKCU:\Software\VbrStdTest-<PID>` key tree and remove it in `finally`. `Get-Service` and `Test-Path` are mocked in child scopes for `Test-Vb365Installed`. Two real binaries with different versions (the .NET core library and the running PowerShell executable) are copied into a test folder to stand in for the Veeam files.

- [ ] **Step 1: Write the failing tests**

Insert this block into `Test-VbrStandardise.ps1` directly above the line `# ===================== RESULT =====================` (below the Task 3 section).

```powershell
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: FAIL. The Task 1-3 checks pass. Then `  FAIL  UNHANDLED  The term 'Get-VbrInstall' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again.` ends the registry block. Its `finally` still removes `HKCU:\Software\VbrStdTest-<PID>`, so `Task 4 registry fixture removed` passes. The three default-root-key checks fail with `got ''`, and the remaining statements fail with `FAIL  UNHANDLED` for `Test-Vb365Installed`, `Get-LocalHostNames`, `Get-DbHostClass` and `Get-RegistryAuthMode`. The last line is `RESULT: 290 passed, 31 failed` (the Task 3 total of 289 plus that one check) and the exit code is 1.

- [ ] **Step 3: Implement**

Insert this block into `Invoke-VbrStandardise.ps1` directly above the line `#endregion Vbr`.

```powershell
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: 363 passed, 0 failed` (the Task 3 total of 289 plus 74 Task 4 checks) and exit code 0. None of the Task 4 checks needs elevation. Afterwards `Test-Path HKCU:\Software\VbrStdTest-*` is `False`. If PowerShell 7 is installed, `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1` gives the same RESULT line.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add VBR registry readers, product detection and host class" -m "Reads the VBR and Enterprise Manager database settings without returning password data, detects VBR and VB365 as the updater does, lists the local host names and classifies SqlHostName, so preflight can decide REMOTE_DB, VBR_DB_NOT_POSTGRES and the registry auth mode." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: PostgreSQL discovery

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region PgDiscovery)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Get-RegValue`, `Get-CfgValue`, `Write-Log` (Task 1). Tests use the Task 1 harness: `Check`, `Throws`, `Skip`, `New-TestFolder`.
- Produces: `Test-PgServiceExecutableMatchesBaseDir`, `Find-PgInstall`, `ConvertFrom-PostmasterPid`, `Test-PostmasterLive`, `Get-PgConfSetting`, `Test-PgConfOverride`, `Select-ListeningLoopback`, `Get-ListeningLoopback` (names, parameters and return shapes exactly as in the shared contract).

These functions cover spec 7.1 steps 11 to 14. None of them calls `Complete-Run`; the main body (Task 18) turns their results into issues. Rules the code follows:
- `Find-PgInstall` returns only the three contract codes. Zero installs, a registry entry without `Version`/`Base Directory`/`Data Directory`, no PostgreSQL service, a service whose name differs from the registry `Service ID`, a service binary outside `Base Directory`, a missing `psql.exe`, or a failed service query give `NO_PG_FOUND` (exit 20). More than one install or more than one PostgreSQL service gives `MULTIPLE_PG` (exit 11). A service that is not `Running` gives `PG_NOT_RUNNING` (exit 20). `Detail` always says which case it was.
- `Test-PgServiceExecutableMatchesBaseDir` is copied from `..\Veeam Postgres Updater\Update-VeeamPostgres.ps1` without changes. `Find-PgInstall` is the updater's STEP 5 moved into a function, with `-Services` so tests can inject service objects (`Name, State, PathName`).
- `Test-PostmasterLive` also checks that line 2 of `postmaster.pid` names the same folder as `-DataDir` (after `/` to `\` and `GetFullPath`, case-insensitive). PostgreSQL writes that line with forward slashes on Windows.
- `ConvertFrom-PostmasterPid` throws on a malformed file; `Test-PostmasterLive` catches that and returns `Ok=$false`.
- `Test-PgConfOverride` follows `include`, `include_if_exists` and `include_dir` the way PostgreSQL does, so an override in an included file is found. It fails closed: when `postgresql.conf` is missing, or an `include`/`include_dir` target cannot be read, or includes nest more than 10 deep, it returns both names and logs why at WARN.

- [ ] **Step 1: Write the failing tests**

Add this section to `Test-VbrStandardise.ps1`, just above the line `# ===================== RESULT =====================`. It needs no VBR and no PostgreSQL. It uses a throwaway key `HKCU:\Software\VbrStdTest-PgInstall-<PID>` (removed in `finally`), folders from `New-TestFolder`, fake service objects, `Get-Process` and `Get-NetTCPConnection` mocks inside `& { }` child scopes, and one real `TcpListener` on `127.0.0.1` with a free port (stopped in `finally`). The `postmaster.pid` sample has the eight lines PostgreSQL writes: PID, data directory, start time, port, socket directory, listen address, shared memory key, status.

```powershell
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`
Expected: FAIL. The Task 1-4 checks still pass. The harness `trap` from Task 1 turns each Task 5 statement that calls a missing function into one `FAIL  UNHANDLED` line and goes on with the next statement, starting with `  FAIL  UNHANDLED  The term 'Test-PgServiceExecutableMatchesBaseDir' is not recognized as the name of a cmdlet, function, script file, or operable program.` followed by the spelling hint. Later lines name `ConvertFrom-PostmasterPid`, `Test-PostmasterLive`, `Get-PgConfSetting`, `Test-PgConfOverride`, `Select-ListeningLoopback`, `Get-ListeningLoopback` and `Find-PgInstall`, or say that a variable such as `$t5Pm` has not been set; the `try` block stops at its first `Find-PgInstall` call and its `finally` removes the throwaway key. Only the three `T5 postmaster.pid ... throws` checks pass, because calling a missing function throws too. On an elevated prompt on a machine without PostgreSQL, the last line is `RESULT: 366 passed, 51 failed` (the Task 4 total of 363 plus those 3) and the exit code is 1. On a machine with PostgreSQL the last check prints `SKIP` instead, so it reads `RESULT: 366 passed, 50 failed`.

- [ ] **Step 3: Implement**

In `Invoke-VbrStandardise.ps1`, insert the five blocks below, in this order, just above the line `#endregion PgDiscovery`.

The service binary check (copied from the updater) and the install discovery (adapted from the updater's STEP 5):

```powershell
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
```

```powershell
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
```

`postmaster.pid` parsing and the live-instance check (spec 7.1 step 12):

```powershell
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
```

`postgresql.conf` settings and the `hba_file`/`ident_file` override check (spec 7.1 step 13):

```powershell
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
```

Listening loopback addresses (spec 7.1 step 14):

```powershell
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`
Expected: `RESULT: <n> passed, 0 failed` and exit code 0, where `<n>` is the total before this task plus 85 (the `T5 ...` checks): `RESULT: 448 passed, 0 failed` on an elevated prompt on English Windows without PostgreSQL or VBR. On a machine that has PostgreSQL installed, two of them print `SKIP` instead (`T5 default key ...` and `T5 without -Services ...`), so `<n>` grows by 83. The same file also passes under `pwsh.exe`.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add PostgreSQL discovery checks" -m "Find the one registered PostgreSQL install and its running service (the updater's STEP 5 moved into Find-PgInstall, with injectable services for tests), prove through postmaster.pid that the registry data directory is the live cluster on the VBR port, refuse hba_file and ident_file overrides including those in included files, and list which loopback addresses listen. These are spec 7.1 steps 11 to 14." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Windows account names for SSPI

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region Names)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Get-CfgValue`, `Write-Log` (Task 1). Tests use the Task 1 harness: `Check`, `Skip`, `$script:LogLines`.
- Produces: `Get-NtAccountParts`, `ConvertTo-SspiMapName`, `Get-SspiMapNameFromSid`, `Test-AsciiText`, `Get-SystemMapNames`, `Resolve-ServiceStartName`, `Get-VeeamServiceAccountNames` (names, parameters and return shapes exactly as in the shared contract).

These functions build the `pg_ident.conf` names of spec 7.3 and the localised-SYSTEM check of spec 7.1 step 15. Rules the code follows:
- Every name comes from a SID through `SecurityIdentifier.Translate([NTAccount])`, the same LSA lookup PostgreSQL uses, in the form `name@domain`. The domain is the case and the 15-character NetBIOS form that LSA returns, which can differ from `$env:COMPUTERNAME` (for example `Ws-Example` and `WS-EXAMPLE`).
- `Resolve-ServiceStartName` returns `MapName = $null` for every kind except `ACCOUNT`. The spaced spellings `NT AUTHORITY\Network Service` and `NT AUTHORITY\Local Service` count as `UNSUPPORTED` too. A translator that returns an empty name gives `UNRESOLVED`.
- `Get-VeeamServiceAccountNames` walks the `Veeam*` services sorted by name. `MapNames` holds each resolved name once (case-insensitive, first spelling kept). `Unresolved` holds each StartName that is `UNSUPPORTED` or `UNRESOLVED`, once; the main body reports them as `SERVICE_ACCOUNT_UNRESOLVED` with the StartNames in `Detail`. If the default `Win32_Service` query fails, `Unresolved` holds one entry that says so, so the run still makes no database change.

- [ ] **Step 1: Write the failing tests**

Add this section to `Test-VbrStandardise.ps1`, just above the line `# ===================== RESULT =====================`. It uses the real SID `S-1-5-18`, the real SID `S-1-1-0` (a name without a domain) and the SID of the account running the tests. Service StartNames go through a fake translator that records what it was asked, so no domain is needed. Three real LSA lookups check the default translator. The checks that expect the English name `SYSTEM@NT AUTHORITY` print `SKIP` on non-English Windows.

```powershell
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`
Expected: FAIL. The Task 1-5 checks still pass. The harness `trap` from Task 1 turns each Task 6 statement that calls a missing function into one `FAIL  UNHANDLED` line and goes on with the next statement, starting with `  FAIL  UNHANDLED  The term 'ConvertTo-SspiMapName' is not recognized as the name of a cmdlet, function, script file, or operable program.` followed by the spelling hint. Later lines name `Get-NtAccountParts`, `Get-SspiMapNameFromSid`, `Test-AsciiText`, `Get-SystemMapNames`, `Resolve-ServiceStartName` and `Get-VeeamServiceAccountNames`, or say that a variable such as `$t6R` has not been set. Two plain checks fail too: `  FAIL  T6 .\x is translated as COMPUTERNAME\x  expected 'HOST1\localsvc' got ''` and `  FAIL  T6 unsupported account logged as WARN with the service name  expected 'True' got 'False'`. Two checks pass without the code: `T6 translator not called for LocalSystem or unsupported names` and `T6 non-Veeam services ignored`. On an elevated prompt on English Windows without PostgreSQL, the last line is `RESULT: 450 passed, 51 failed` (the Task 5 total of 448 plus those 2) and the exit code is 1.

- [ ] **Step 3: Implement**

In `Invoke-VbrStandardise.ps1`, insert the three blocks below, in this order, just above the line `#endregion Names`.

SID to `name@domain`:

```powershell
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
```

The ASCII check and the SYSTEM names (spec 7.1 step 15):

```powershell
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
```

Service StartName resolution (spec 7.3, service account lines):

```powershell
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`
Expected: `RESULT: <n> passed, 0 failed` and exit code 0, where `<n>` is the total before this task plus 53 (the `T6 ...` checks) on English Windows when the tests run as a local account: `RESULT: 501 passed, 0 failed` on an elevated prompt without PostgreSQL or VBR. On non-English Windows three checks print `SKIP` (`<n>` grows by 50). When the tests run as a domain account, `T6 default translator resolves .\ for a local account` prints `SKIP`. The same file also passes under `pwsh.exe`.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add Windows account names for the SSPI map" -m "Build pg_ident names as name@domain from SIDs through the same LSA lookup PostgreSQL uses, detect a non-ASCII SYSTEM name for PG_IDENT_LOCALISED, and resolve the StartName of every Veeam service that does not run as LocalSystem. NetworkService, LocalService, gMSA and unresolvable accounts come back as unresolved, so the run can report SERVICE_ACCOUNT_UNRESOLVED and make no database change (spec 7.1 step 15 and 7.3)." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: svc_veeam account check and fix

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region Account)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Get-CfgValue`, `Write-Log`, `Format-ShortText` (Task 1); `Add-RunIssue` (Task 2); `Get-NtAccountParts`, `Get-SspiMapNameFromSid` (Task 6). The tests also use `Get-DefaultConfig` (Task 1) and the harness API (`Check`, `Throws`, `Skip`, `$script:LogLines`).
- Produces: `Get-ServiceAccountInfo`, `Get-ServiceAccountStatus`, `Test-AdministratorsMember`, `Add-AdministratorsMember`, `Read-ServiceAccountPassword`, `ConvertTo-AccountIssueCode`, `New-ServiceAccount`, `Set-ServiceAccountFlags`, `Invoke-ServiceAccountStep`.

- [ ] **Step 1: Write the failing tests**

These tests never create a user and never change a group:
- `New-LocalUser`, `Set-LocalUser` and `Add-LocalGroupMember` are mocked by functions in `& { }` child scopes. A function beats a cmdlet, in `Get-Command` too, so the real cmdlets never run. The fake SID used with `Add-LocalGroupMember` does not exist either.
- The error mapping is tested with fake exception classes that carry the LocalAccounts type names.
- The only real ADSI reads are a name that does not exist, the Administrators group and the built-in Administrator (RID 500).
- `Invoke-ServiceAccountStep` is tested with every system call mocked. Two extra scenarios use the real `Read-ServiceAccountPassword` with a throwaway variable `VBRSTD_T7_PW_<PID>`.
- Disposal of a `SecureString` is checked with `.Copy()`. Windows PowerShell returns `$null` for `.Length` on a disposed `SecureString` instead of throwing.

Insert this block in `Test-VbrStandardise.ps1` directly above the line `# ===================== RESULT =====================`.

```powershell
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: FAIL. The earlier sections still pass. The harness `trap` from Task 1 turns each Task 7 statement that calls a missing function into one `FAIL  UNHANDLED` line and goes on with the next statement, starting with `  FAIL  UNHANDLED  The term 'Get-ServiceAccountStatus' is not recognized as the name of a cmdlet, function, script file, or operable program.` followed by the spelling hint. Later lines name the other eight Task 7 functions, or say that a variable such as `$t7s` has not been set. Three plain checks fail too: `T7 password: variable removed from the process`, `T7 password: env drive no longer has it` and `T7 add admin: MemberExistsException counts as success`. Three checks pass without the code: `T7 password: never logged`, `T7 add admin: other errors are thrown` and `T7 create: other errors are thrown`. With the Task 6 total of 501, the last line is `RESULT: 504 passed, 93 failed` and the exit code is 1.

- [ ] **Step 3: Implement**

Facts the code relies on (spec 7.2, `research_local-account.md`; checked on Windows PowerShell 5.1):
- Read the account through ADSI `WinNT://<COMPUTERNAME>/<name>,user`.
  - A missing name makes `RefreshCache()` throw HRESULT `0x800708AD` (NERR_UserNotFound). PowerShell wraps it: the outer exception is an `ExtendedTypeSystemException` and the `COMException` is inside it, so the code walks the inner exceptions.
  - A local group bound with `,user` also gives `0x800708AD`. Binding it with `,group` then works, which is how `SVC_NAME_IN_USE` is found.
  - A missing group gives `0x800708AC`.
  - On an entry that never bound, even `.Dispose()` throws, so every dispose is wrapped in `try { } catch { }`.
- Check Administrators membership by SID (`S-1-5-32-544`) through ADSI `Invoke('Members')`. The LocalAccounts member-list cmdlet is forbidden (Global Constraints), because it fails on orphaned SIDs. Do not write its name even in a comment, because Task 18 scans the script text.
- Account never expires is not a UserFlags bit. `Properties.Contains('AccountExpirationDate')` is `$false` when the account never expires. Never read that property directly.
- Compare HRESULTs as 8-digit hex text (`'{0:X8}' -f $ex.HResult`). This avoids the different hex-literal rules of 5.1 and 7.
- `Invoke-ServiceAccountStep` reads and clears `VEEAM_SVC_PASSWORD` first, in every mode, even when the account exists. The secret then never stays in the process environment, where `psql.exe` and `reg.exe` would inherit it.
- The ADSI fallbacks in `New-ServiceAccount`, `Set-ServiceAccountFlags` and `Add-AdministratorsMember` run only when the LocalAccounts cmdlets are missing. No test covers them, because a test would have to create a real account.

Insert the nine functions below in `Invoke-VbrStandardise.ps1`, in this order, directly above the line `#endregion Account`. They are pasted as one block.

```powershell
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: <n> passed, 0 failed` and exit code 0. Task 7 adds 143 checks, so `<n>` is 143 more than after Task 6: `RESULT: 644 passed, 0 failed` on an elevated prompt on English Windows without PostgreSQL or VBR. On a machine where the built-in Administrator (RID 500) cannot be found, 8 of them print `SKIP` instead, and `<n>` is 135 more.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add svc_veeam account check and fix" -m "Reads the account through ADSI WinNT and checks Administrators membership by SID, so orphaned SIDs cannot break the check. Maps New-LocalUser errors by exception type name. Fixes membership and flags only with -Apply or -CreateServiceAccount. Creates the account only with -CreateServiceAccount. Reads VEEAM_SVC_PASSWORD once and clears it in every mode, so the secret never reaches a log or a child process." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Config file byte IO and atomic write

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region ConfFiles)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Write-Log -Message <string> [-Level <string>]` (Task 1).
- Produces: `ConvertFrom-Latin1Bytes -Bytes`, `ConvertTo-Latin1Bytes -Text`, `Get-Sha256Hex -Bytes`, `Read-ConfFile -Path`, `Split-ConfLines -Text`, `Join-ConfLines -Lines -LineEnding`, `Write-ConfFileAtomic -Path -Bytes -ExpectedSddl`, `Backup-ConfFile -Path -RunDir`, `Restore-ConfFile -Path -BackupPath -ExpectedSddl`.

Notes for the engineer:
- This task covers spec 7.8 and the Global Constraint on config files. Latin-1 (code page 28591) maps each byte to one char and back, so the text functions never change a byte they do not touch.
- **Return shapes.**
  - `ConvertTo-Latin1Bytes` returns its `byte[]` with a leading comma, so `$b = ConvertTo-Latin1Bytes -Text $t` is a `byte[]` and is never unrolled.
  - `Split-ConfLines` returns its lines the normal way. Always call it as `@(Split-ConfLines -Text $x)`: one line comes back as a plain string, and no lines come back as nothing.
- **No silent `?`.** `ConvertTo-Latin1Bytes` throws on any char above U+00FF instead of writing `?`.
- **Why the temp file gets an owner and group.** `[IO.File]::Replace` keeps the live file's DACL, but the replaced file takes its owner and group from the temp file. This was measured on Windows 11 under PowerShell 5.1 and 7.4.
  - A real `pg_hba.conf` is not owned by the identity that runs the script, so a plain swap would fail the SDDL check on every write.
  - `Write-ConfFileAtomic` therefore copies the live file's owner and group onto the temp file with `Set-Acl` before the swap. `Set-Acl` enables the restore privilege that this needs.
  - The test fixtures are owned by SYSTEM: one has a protected DACL, and one has only inherited ACEs (the usual shape in a PostgreSQL data folder). If the `Set-Acl` line is removed, these tests fail.
- **What happens on a failure.**
  - `Write-ConfFileAtomic` first checks whether the live file still holds the previous bytes and SDDL. This is the case when, for example, another process holds the file without delete sharing and Replace refuses. In that case it writes nothing more.
  - Otherwise it swaps the previous bytes back with the same routine.
  - If Replace renamed the live file to the backup name and then failed (ERROR_UNABLE_TO_MOVE_REPLACEMENT_2), it renames that file back. That file is the live file itself, with its own ACL. It is never a run-folder file.
  - The exception message says which case happened: "still holds its previous bytes", "previous bytes were put back", or "putting the previous bytes back also failed" (with the path of the kept `.old` file).
- **Limits.**
  - `Write-ConfFileAtomic` only replaces an existing file. For a missing file it throws and creates nothing.
  - `Backup-ConfFile` never overwrites an existing `.before` file.
  - `Restore-ConfFile` writes nothing when the live file already holds the backup bytes and the expected SDDL. Path A can therefore restore both files after it wrote only one.
- **Temp file names.** The temp and swap-backup files are `<file>.vbrstd-<PID>-<guid>.tmp` and `.old`, next to the live file. PostgreSQL never reads them, because `include_dir` only reads `*.conf`.
- **Elevation.** The tests must run elevated, because they give a temp file a SYSTEM-owned ACL.

- [ ] **Step 1: Write the failing tests**

Insert this block in `Test-VbrStandardise.ps1` directly above the line `# ===================== RESULT =====================`. Each group runs inside its own `& { try { ... } catch { ... } }`. A missing function then shows as one FAIL line, and the other groups still run.

```powershell
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected:
- Every check from Tasks 1-7 still passes.
- The five static checks fail with `expected 'True' got 'False'`, for example `FAIL  T8 Restore-ConfFile exists and never moves or copies a file into the data folder  expected 'True' got 'False'`.
- Four group lines fail with the missing function, for example `FAIL  T8 Latin-1 and SHA-256 checks ran without an error  expected '' got 'The term 'ConvertFrom-Latin1Bytes' is not recognized as the name of a cmdlet, function, script file, or operable program. ...'`. The other three name `Read-ConfFile`, `Write-ConfFileAtomic` and `Backup-ConfFile`.
- Two fixture checks already pass: `T8 fixture ACL is distinctive` and `T8 a new file in the folder gets another SDDL`.
- The last line is `RESULT: <n> passed, 9 failed`, and the exit code is 1.

- [ ] **Step 3: Implement**

Insert this block in `Invoke-VbrStandardise.ps1` directly above the line `#endregion ConfFiles`.

```powershell
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: <n> passed, 0 failed`, where `<n>` is Task 7's passed count plus 71 (`RESULT: 715 passed, 0 failed` on an elevated prompt on English Windows without PostgreSQL or VBR). The exit code is 0. The same 71 checks also pass under `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add byte-safe config file IO and atomic write" -m "Read pg_hba.conf and pg_ident.conf as bytes and edit them as Latin-1 text, so CP1252 or UTF-8 bytes in comments survive unchanged and a BOM is never written back. Write-ConfFileAtomic swaps new bytes in with File.Replace and a backup in the same folder. File.Replace keeps only the DACL, so the temp file first gets the live file's owner and group. The routine checks SHA-256 and SDDL and puts the previous bytes back on any failure. Restore-ConfFile uses the same routine, so a run-folder ACL never reaches the data folder (spec 7.8)." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: pg_hba.conf parse, check and render

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region PgHba)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Get-CfgValue -Object -Name -Default` (Task 1), `Test-AsciiText -Text` (Task 6), `Join-ConfLines -Lines -LineEnding` (Task 8). The tests also use `Split-ConfLines -Text`, `ConvertFrom-Latin1Bytes -Bytes` and `ConvertTo-Latin1Bytes -Text` (Task 8).
- Produces: `Split-ConfTokens -Line`, `Get-PgHbaRules -Lines`, `Test-PgHbaHasInclude -Lines`, `Get-StandardPgHbaLines`, `Test-PgHbaStandard -Rules`, `Get-NonLoopbackHbaRules -Rules`, `Get-HbaFirstMatch -Rules -Database -User -Address`, `New-PgHbaText -Lines -LineEnding -Stamp`.

Notes for the engineer:
- This task covers spec 7.1 step 13, 7.3, 7.4, 7.5 and 7.8.
- These are pure functions with no file or system access. Callers pass `@(Split-ConfLines -Text $Ctx.Hba.Text)`, and write the result of `New-PgHbaText` with `ConvertTo-Latin1Bytes` + `Write-ConfFileAtomic`.
- **Tokens follow PostgreSQL.**
  - Space, tab, CR and LF separate tokens.
  - Double quotes keep a token whole and are removed.
  - `#` outside quotes starts a comment.
  - Because the quotes are removed, a quoted `"all"` reads as the keyword `all`. Both functions that this affects err to the safe side:
    - In `Get-HbaFirstMatch`, more lines match.
    - In `Test-PgHbaHasInclude`, a quoted `"@x"` counts as an include, so the run stops with `PG_HBA_INCLUDE`.
- **`Get-PgHbaRules`** returns a rule for every active line, including `include*` lines (Type = the keyword, arguments in Database). `Test-PgHbaStandard` therefore never calls a file with extra lines standard.
- **`Test-PgHbaStandard`** compares Type, Database, User, Address and Method case-insensitively. It compares Options as a set of words, case-sensitively, because in PostgreSQL `map=Veeam` names a different map. Rules may be objects or hashtables; they are read with `Get-CfgValue`.
- **`Get-HbaFirstMatch` is conservative.**
  - Anything it cannot decide offline counts as a match: `samerole`, `+group`, `@file`, `/regex`, host names, `samehost`, `samenet`, `hostssl` and `hostnossl`. It can therefore answer "the first matching rule may be another one", but never give a false "the first rule is sspi map=veeam". That false answer is the one that would wrongly allow DbAuth = WINDOWS (spec 7.4).
  - Database and user names compare case-sensitively.
  - `replication` never matches a normal connection.
  - `-Address` must be an IP literal (`127.0.0.1` or `::1`). Anything else throws.
- **PostgreSQL 16 line continuation** (a line ending in `\`). Every physical line is commented out on its own. If a commented line ends in `\`, PostgreSQL joins the next line into that comment. That next line is also an original line, which is commented out too, so the result is the same. The header and the six standard lines come first and never end in `\`.
- **Fixtures.** They are script-scope variables named `$T9*`, shared by the five groups below.

- [ ] **Step 1: Write the failing tests**

Insert this block in `Test-VbrStandardise.ps1` directly above the line `# ===================== RESULT =====================`.

```powershell
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
    } catch {
        Check 'T9 token checks ran without an error' $_.Exception.Message ''
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

        Check 'T9 stock native file has no include' (Test-PgHbaHasInclude -Lines @(Split-ConfLines -Text $T9Native)) $false
        Check 'T9 Veeam default file has no include' (Test-PgHbaHasInclude -Lines @(Split-ConfLines -Text $T9Veeam)) $false
        Check 'T9 include_dir is an include' (Test-PgHbaHasInclude -Lines @(Split-ConfLines -Text $T9IncludeDir)) $true
        Check 'T9 include "file" is an include' (Test-PgHbaHasInclude -Lines @(Split-ConfLines -Text $T9IncludeFile)) $true
        Check 'T9 include_if_exists is an include' (Test-PgHbaHasInclude -Lines @('include_if_exists extra.conf')) $true
        Check 'T9 @file in the user column is an include' (Test-PgHbaHasInclude -Lines @($T9AtFile)) $true
        Check 'T9 @file inside a comma list is an include' (Test-PgHbaHasInclude -Lines @('host VeeamBackup,@dbs.txt all 127.0.0.1/32 md5')) $true
        Check 'T9 a commented include is not an include' (Test-PgHbaHasInclude -Lines @('# include_dir conf.d')) $false
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected:
- Every check from Tasks 1-8 still passes.
- Five group lines fail, one per group. Each names the first missing function, for example `FAIL  T9 token checks ran without an error  expected '' got 'The term 'Split-ConfTokens' is not recognized as the name of a cmdlet, function, script file, or operable program. ...'`. The other four name `Get-PgHbaRules`, `Get-StandardPgHbaLines`, `Get-PgHbaRules` and `New-PgHbaText`.
- The last line is `RESULT: <n> passed, 5 failed`, and the exit code is 1.

- [ ] **Step 3: Implement**

Insert this block in `Invoke-VbrStandardise.ps1` directly above the line `#endregion PgHba`.

```powershell
# Splits one pg_hba.conf or pg_ident.conf line into tokens. Space, tab, CR and LF
# separate tokens (PostgreSQL's blanks; a Latin-1 0xA0 is not one). Double quotes keep
# a token whole and are removed. '#' outside quotes starts a comment. Callers wrap the
# result in @().
function Split-ConfTokens {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Line)
    $tokens = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    $inQuote = $false
    $hasToken = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($inQuote) {
            if ($ch -eq [char]34) { $inQuote = $false } else { [void]$current.Append($ch) }
            continue
        }
        if ($ch -eq [char]34) {
            $inQuote = $true
            $hasToken = $true
            continue
        }
        if ($ch -eq [char]35) { break }
        if ($ch -eq [char]32 -or $ch -eq [char]9 -or $ch -eq [char]13 -or $ch -eq [char]10) {
            if ($hasToken) {
                $tokens.Add($current.ToString())
                [void]$current.Clear()
                $hasToken = $false
            }
            continue
        }
        [void]$current.Append($ch)
        $hasToken = $true
    }
    if ($hasToken) { $tokens.Add($current.ToString()) }
    return $tokens.ToArray()
}

# One object per active pg_hba.conf line: { LineIndex; Type; Database; User; Address;
# Method; Options }. local lines have Address ''. An IP address followed by a netmask
# column becomes address/prefix. Options is the rest of the line joined by one space.
# A line of any other type (include, include_dir, ...) is still returned, with its
# arguments in Database, so no active line is ever invisible to Test-PgHbaStandard.
function Get-PgHbaRules {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines)
    $isIpLiteral = {
        param([string] $Text)
        $ip = $null
        return ((($Text -match '^\d{1,3}(\.\d{1,3}){3}$') -or $Text.Contains(':')) -and
            [System.Net.IPAddress]::TryParse($Text, [ref]$ip))
    }
    $rules = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Lines.Length; $i++) {
        $t = @(Split-ConfTokens -Line $Lines[$i])
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
            LineIndex = $i
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
    foreach ($line in $Lines) {
        $t = @(Split-ConfTokens -Line $line)
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: <n> passed, 0 failed`, where `<n>` is Task 8's passed count plus 83 (`RESULT: 798 passed, 0 failed` on an elevated prompt on English Windows without PostgreSQL or VBR). The exit code is 0.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Parse, check and render pg_hba.conf" -m "Tokenise pg_hba.conf the way PostgreSQL does and return a rule for every active line, with an address and netmask pair turned into a CIDR prefix. Test-PgHbaStandard checks the six lines of Veeam's default SSPI layout in order. Get-HbaFirstMatch counts anything it cannot decide offline as a match, so it never reports a false sspi first match. New-PgHbaText puts the standard lines first and comments out every original active line with an ASCII prefix, keeping the original bytes (spec 7.3, 7.8)." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: pg_ident.conf parse, check and render

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region PgIdent)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Get-CfgValue -Object -Name -Default` (Task 1), `Test-AsciiText -Text` (Task 6), `Join-ConfLines -Lines -LineEnding` (Task 8), `Split-ConfTokens -Line` (Task 9). The tests also use `Split-ConfLines -Text`, `ConvertFrom-Latin1Bytes -Bytes` and `ConvertTo-Latin1Bytes -Text` (Task 8).
- Produces: `Get-PgIdentEntries -Lines`, `Get-RequiredIdentNames -SvcMapName [-ServiceAccountMapNames]`, `Get-PgIdentStatus -Entries -RequiredNames`, `New-PgIdentText -Lines -RequiredNames -LineEnding -Stamp`.

Notes for the engineer:
- This task covers spec 7.3 and 7.8, and decision D6. These are pure functions.
- **Which lines are managed.**
  - Only the map named exactly `veeam` is managed. The map name is case-sensitive, as in PostgreSQL, so a `Veeam` line belongs to another map and is never touched.
  - System user names compare case-insensitively, because PostgreSQL compares SSPI names case-insensitively.
  - The role must be exactly `postgres`.
- **Status rules.**
  - A required name that appears twice is not an extra entry.
  - A `veeam` entry with a regex system user (`/...`) is never a required literal. It is therefore an extra entry and gets commented out.
- **`Get-RequiredIdentNames`** skips an empty or `$null` `-SvcMapName`. AUDIT on a server without svc_veeam can still build the list.
- **ASCII only for new lines.** `New-PgIdentText` throws if a name it must append is not printable ASCII or contains a double quote, because new lines are ASCII only (Global Constraints).
  - Tasks 16 and 17 render both new texts (pg_hba and pg_ident) before they take a backup, write the marker or stop a service. This throw then stops the run with nothing changed, never with one file changed and the other not.
  - An existing `veeam` line that already maps a required non-ASCII name to `postgres` is kept as its original bytes.
- **Fixtures.** They are script-scope variables named `$T10*`, shared by the three groups below.

- [ ] **Step 1: Write the failing tests**

Insert this block in `Test-VbrStandardise.ps1` directly above the line `# ===================== RESULT =====================`.

```powershell
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected:
- Every check from Tasks 1-9 still passes.
- Three group lines fail, for example `FAIL  T10 entry and required-name checks ran without an error  expected '' got 'The term 'Get-PgIdentEntries' is not recognized as the name of a cmdlet, function, script file, or operable program. ...'`. The other two name `Get-RequiredIdentNames`.
- The last line is `RESULT: <n> passed, 3 failed`, and the exit code is 1.

- [ ] **Step 3: Implement**

Insert this block in `Invoke-VbrStandardise.ps1` directly above the line `#endregion PgIdent`.

```powershell
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

# The names the veeam map must hold (spec 7.3): SYSTEM, then svc_veeam, then the
# accounts of Veeam services that do not run as LocalSystem. Duplicates are removed
# case-insensitively (PostgreSQL compares SSPI names case-insensitively); the first
# spelling wins. Empty names are skipped, so a missing svc_veeam gives no empty line.
function Get-RequiredIdentNames {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $SvcMapName,
        [string[]] $ServiceAccountMapNames = @()
    )
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($name in (@('SYSTEM@NT AUTHORITY', $SvcMapName) + @($ServiceAccountMapNames))) {
        if ([string]::IsNullOrEmpty($name)) { continue }
        if ($seen.Add($name)) { $names.Add($name) }
    }
    return $names.ToArray()
}

# STANDARD when the veeam map holds every required name mapped to postgres and nothing
# else. MISSING_ENTRY when a required name has no veeam entry to postgres; EXTRA_ENTRY
# when a veeam entry is not required or maps to another role. MISSING wins over EXTRA.
# System names compare case-insensitively. The map name and the role are
# case-sensitive, as in PostgreSQL: 'Veeam' is another map, 'Postgres' another role.
function Get-PgIdentStatus {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Entries,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $RequiredNames
    )
    $required = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $RequiredNames) { if (-not [string]::IsNullOrEmpty($name)) { [void]$required.Add($name) } }
    $mapped = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $extra = $false
    foreach ($entry in $Entries) {
        if ([string](Get-CfgValue -Object $entry -Name 'Map' -Default '') -cne 'veeam') { continue }
        $systemUser = [string](Get-CfgValue -Object $entry -Name 'SystemUser' -Default '')
        $pgUser = [string](Get-CfgValue -Object $entry -Name 'PgUser' -Default '')
        if ($pgUser -ceq 'postgres' -and $required.Contains($systemUser)) {
            [void]$mapped.Add($systemUser)
        } else {
            $extra = $true
        }
    }
    foreach ($name in $required) {
        if (-not $mapped.Contains($name)) { return 'MISSING_ENTRY' }
    }
    if ($extra) { return 'EXTRA_ENTRY' }
    return 'STANDARD'
}

# The new pg_ident.conf text (spec 7.8). Lines outside the veeam map stay as they are.
# A veeam line that is not required, or maps to another role, gets the ASCII prefix
# '# [VbrStandardise <Stamp>] ' in front of its original characters. Each required name
# without a veeam line to postgres is appended as: veeam   "<name>"   postgres
# New lines are ASCII only: a name that is not printable ASCII, or holds a double
# quote, is refused (throw) rather than written.
function New-PgIdentText {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $RequiredNames,
        [Parameter(Mandatory = $true)][string] $LineEnding,
        [Parameter(Mandatory = $true)][string] $Stamp
    )
    if (-not (Test-AsciiText -Text $Stamp)) { throw "New-PgIdentText: the stamp '$Stamp' is not printable ASCII." }
    $required = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $RequiredNames) { if (-not [string]::IsNullOrEmpty($name)) { [void]$required.Add($name) } }
    $mapped = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $prefix = "# [VbrStandardise $Stamp] "
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $t = @(Split-ConfTokens -Line $line)
        if ($t.Count -eq 0 -or $t[0] -cne 'veeam') {
            $out.Add($line)
            continue
        }
        $systemUser = ''
        $pgUser = ''
        if ($t.Count -gt 1) { $systemUser = $t[1] }
        if ($t.Count -gt 2) { $pgUser = $t[2] }
        if ($pgUser -ceq 'postgres' -and $required.Contains($systemUser)) {
            $out.Add($line)
            [void]$mapped.Add($systemUser)
        } else {
            $out.Add($prefix + $line)
        }
    }
    foreach ($name in $RequiredNames) {
        if ([string]::IsNullOrEmpty($name) -or $mapped.Contains($name)) { continue }
        if (-not (Test-AsciiText -Text $name) -or $name.Contains('"')) {
            throw "New-PgIdentText: the name '$name' is not printable ASCII or holds a double quote. It is not written to pg_ident.conf."
        }
        $out.Add('veeam   "' + $name + '"   postgres')
        [void]$mapped.Add($name)
    }
    return (Join-ConfLines -Lines $out.ToArray() -LineEnding $LineEnding)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: <n> passed, 0 failed`, where `<n>` is Task 9's passed count plus 47 (`RESULT: 845 passed, 0 failed` on an elevated prompt on English Windows without PostgreSQL or VBR). The exit code is 0.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Parse, check and render pg_ident.conf" -m "Read the veeam map from pg_ident.conf and compare it with the required names: SYSTEM, svc_veeam and the accounts of Veeam services that do not run as LocalSystem. Names compare case-insensitively, as PostgreSQL does for SSPI; the map and role names are case-sensitive. New-PgIdentText keeps every other map, comments out veeam lines that are not required or map to another role, appends missing names as ASCII lines, and keeps the original bytes of every existing line (spec 7.3, 7.8, D6)." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: psql runner, SSPI test and live queries

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region Psql)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Invoke-Native -FilePath -Arguments [-StdinText]`, `Write-Log -Message -Level`, `Format-ShortText -Text -MaxLength`, `Get-CfgValue -Object -Name -Default`, `ConvertFrom-JsonArrayText -Text` (all Task 1).
- Produces: `Invoke-PgQuery`, `Get-PsqlFailureKind`, `Test-PgSspiLogin`, `ConvertTo-ComparablePath`, `Test-SamePath`, `Test-PgConfigHealth`, `Get-PgLiveState`, `Get-OtherPasswordRoles`, `Clear-PostgresPassword`.

Notes for the engineer:
- Spec 7.9 and 7.10. Every psql call goes through `Invoke-PgQuery`, so the libpq environment rules live in one place. The SQL never contains a double quote, because Windows PowerShell 5.1 does not escape embedded double quotes when it builds a native command line.
- The `pg_authid` queries read `rolpassword IS NULL` as text (`NONE`/`SET`) or use it only as a filter. No query selects the hash.
- Backend start times come back as epoch milliseconds, not as date strings, so `ConvertFrom-Json` on PowerShell 7 cannot turn them into local-time `DateTime` values behind our back.
- No PostgreSQL is needed for the tests. `Invoke-PgQuery` is tested against a fake `psql.cmd` that writes its arguments, the libpq variables it sees and its stdin to files. Everything else mocks `Invoke-PgQuery` in a child scope.

- [ ] **Step 1: Write the failing tests**

Insert this block in `Test-VbrStandardise.ps1` directly above the line `# ===================== RESULT =====================`. Each group runs inside `try`, so a missing function shows as one FAIL line and the run goes on.

```powershell
# --- Task 11: psql runner, SSPI test and live queries ---
try {
    & {
        $dir = New-TestFolder 'psql'
        $fakePsql = Join-Path $dir 'psql.cmd'
        # Fake psql: writes each argument on its own line, the libpq variables it
        # sees, and stdin when it is called with "-f -". Host ::1 fails like a
        # refused login (exit 2, message on stderr); any other host prints 1.
        $fakeText = @'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "OUT=%~dp0"
set "HOSTARG=%~4"
>"%OUT%env.txt" echo PGPASSFILE=[%PGPASSFILE%]
>>"%OUT%env.txt" echo PGCONNECT_TIMEOUT=[%PGCONNECT_TIMEOUT%]
>>"%OUT%env.txt" echo PGPASSWORD=[%PGPASSWORD%]
>>"%OUT%env.txt" echo PGUSER=[%PGUSER%]
>>"%OUT%env.txt" echo PGHOST=[%PGHOST%]
>>"%OUT%env.txt" echo PGSERVICE=[%PGSERVICE%]
>>"%OUT%env.txt" echo PGSSLMODE=[%PGSSLMODE%]
type nul >"%OUT%args.txt"
if exist "%OUT%stdin.txt" del "%OUT%stdin.txt"
set "READSTDIN="
:next
if "%~1"=="" goto done
>>"%OUT%args.txt" echo(%~1
if "%~1"=="-f" if "%~2"=="-" set "READSTDIN=1"
shift
goto next
:done
if defined READSTDIN findstr "^" >"%OUT%stdin.txt"
if "%HOSTARG%"=="::1" goto refuse
echo 1
exit /b 0
:refuse
>&2 echo psql: error: connection to server at "::1", port 5432 failed: FATAL:  no pg_hba.conf entry for host "::1", user "postgres", database "VeeamBackup", no encryption
exit /b 2
'@
        # cmd.exe needs CRLF line ends for labels and goto to work reliably.
        [IO.File]::WriteAllText($fakePsql, ($fakeText -replace "`r?`n", "`r`n"), [Text.Encoding]::ASCII)
        $argsFile  = Join-Path $dir 'args.txt'
        $envFile   = Join-Path $dir 'env.txt'
        $stdinFile = Join-Path $dir 'stdin.txt'

        $pgNames = @('PGPASSFILE', 'PGCONNECT_TIMEOUT', 'PGPASSWORD', 'PGUSER', 'PGHOST', 'PGSERVICE', 'PGSSLMODE')
        $before = @{}
        foreach ($n in $pgNames) { $before[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
        try {
            $old = @{ PGPASSFILE = 'C:\old\pgpass.conf'; PGCONNECT_TIMEOUT = $null; PGPASSWORD = 'old-secret-sentinel'; PGUSER = 'olduser'; PGHOST = 'oldhost'; PGSERVICE = 'oldservice'; PGSSLMODE = 'require' }
            foreach ($n in $pgNames) { [Environment]::SetEnvironmentVariable($n, $old[$n], 'Process') }
            $expectedDuring   = 'PGPASSFILE=[nul];PGCONNECT_TIMEOUT=[10];PGPASSWORD=[];PGUSER=[];PGHOST=[];PGSERVICE=[];PGSSLMODE=[]'
            $expectedRestored = 'PGPASSFILE=[C:\old\pgpass.conf];PGCONNECT_TIMEOUT=[];PGPASSWORD=[old-secret-sentinel];PGUSER=[olduser];PGHOST=[oldhost];PGSERVICE=[oldservice];PGSSLMODE=[require]'
            $currentEnv = { (@($pgNames | ForEach-Object { "$_=[$([Environment]::GetEnvironmentVariable($_, 'Process'))]" })) -join ';' }

            $r = Invoke-PgQuery -Psql $fakePsql -Port 5432 -HostAddress '127.0.0.1' -Database 'VeeamBackup' -Sql 'SELECT 1;'
            Check 'psql: exit code of a good call'                    $r.ExitCode 0
            Check 'psql: stdout of a good call'                       $r.StdOut '1'
            Check 'psql: -c call arguments in order'                  (@(Get-Content -LiteralPath $argsFile) -join ' ') '-X -w -h 127.0.0.1 -p 5432 -U postgres -d VeeamBackup -t -A -c SELECT 1;'
            Check 'psql: libpq environment during a -c call'          (@(Get-Content -LiteralPath $envFile) -join ';') $expectedDuring
            Check 'psql: nothing read from stdin for a -c call'       (Test-Path -LiteralPath $stdinFile) 'False'
            Check 'psql: old environment restored after a -c call'    (& $currentEnv) $expectedRestored
            Check 'psql: PGCONNECT_TIMEOUT absent again'              (Test-Path Env:\PGCONNECT_TIMEOUT) 'False'

            $r = Invoke-PgQuery -Psql $fakePsql -Port 5433 -HostAddress '127.0.0.1' -Database 'VeeamBackup' -Sql 'ALTER ROLE postgres PASSWORD NULL;' -ViaStdin
            Check 'psql: exit code of a stdin call'                   $r.ExitCode 0
            Check 'psql: stdin call arguments end with -f -'          (@(Get-Content -LiteralPath $argsFile) -join ' ') '-X -w -h 127.0.0.1 -p 5433 -U postgres -d VeeamBackup -t -A -f -'
            Check 'psql: SQL arrives on stdin'                        ((@(Get-Content -LiteralPath $stdinFile) -join '').Trim()) 'ALTER ROLE postgres PASSWORD NULL;'
            Check 'psql: libpq environment during a stdin call'       (@(Get-Content -LiteralPath $envFile) -join ';') $expectedDuring
            Check 'psql: old environment restored after a stdin call' (& $currentEnv) $expectedRestored

            $r = Invoke-PgQuery -Psql $fakePsql -Port 5432 -HostAddress '::1' -Database 'VeeamBackup' -Sql 'SELECT 1;'
            Check 'psql: failing exit code returned'                  $r.ExitCode 2
            Check 'psql: failing stderr returned'                     ($r.StdErr -match 'no pg_hba\.conf entry') 'True'
            Check 'psql: failing stdout is empty'                     $r.StdOut ''
            Check 'psql: old environment restored after a failure'    (& $currentEnv) $expectedRestored

            & {
                function Invoke-Native {
                    [CmdletBinding()] param([string] $FilePath, [string[]] $Arguments, [string] $StdinText)
                    throw 'simulated psql start failure'
                }
                Throws 'psql: a runner exception propagates' { Invoke-PgQuery -Psql 'missing-psql.exe' -Port 5432 -HostAddress '127.0.0.1' -Database 'VeeamBackup' -Sql 'SELECT 1;' }
                Check 'psql: old environment restored after an exception' (& $currentEnv) $expectedRestored
            }
        } finally {
            foreach ($n in $pgNames) { [Environment]::SetEnvironmentVariable($n, $before[$n], 'Process') }
        }
    }
} catch {
    Check 'Task 11: Invoke-PgQuery tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        $cases = [ordered]@{
            'psql: error: connection to server at "127.0.0.1", port 5432 failed: FATAL:  SSPI authentication failed for user "postgres"' = 'AUTH'
            'FATAL:  no pg_hba.conf entry for host "::1", user "postgres", database "VeeamBackup", no encryption' = 'AUTH'
            'FATAL:  no match in usermap "veeam" for user "postgres" authenticated as "Administrator@VBR01"' = 'AUTH'
            'FATAL:  password authentication failed for user "postgres"' = 'AUTH'
            'fe_sendauth: no password supplied' = 'AUTH'
            'FATAL:  28000: Benutzerzuordnung fehlgeschlagen' = 'AUTH'
            'FATAL:  28P01: Passwort-Authentifizierung fehlgeschlagen' = 'AUTH'
            'NOTICE:  copied 28000 rows' = 'OTHER'
            'connection to server at "::1", port 5432 failed: Connection refused (0x0000274D/10061)' = 'CONNECT'
            'could not connect to server: Connection timed out' = 'CONNECT'
            'psql: error: timeout expired' = 'CONNECT'
            'ERROR:  relation "pg_ident_file_mappings" does not exist' = 'OTHER'
            'server closed the connection unexpectedly' = 'OTHER'
        }
        $i = 0
        foreach ($text in @($cases.Keys)) {
            $i++
            Check "psql failure kind $i is $($cases[$text])" (Get-PsqlFailureKind -StdErr $text) $cases[$text]
        }
        Check 'psql failure kind of empty stderr is OTHER' (Get-PsqlFailureKind -StdErr '') 'OTHER'
        Check 'psql failure kind of null stderr is OTHER'  (Get-PsqlFailureKind -StdErr $null) 'OTHER'
    }
} catch {
    Check 'Task 11: Get-PsqlFailureKind tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        $calls = New-Object System.Collections.ArrayList
        function Invoke-PgQuery {
            param([string] $Psql, [int] $Port, [string] $HostAddress, [string] $Database, [string] $Sql, [switch] $ViaStdin)
            [void]$calls.Add("$HostAddress|$Port|$Database|$Sql|$ViaStdin")
            if ($HostAddress -eq '::1') {
                return [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'connection to server at "::1", port 5432 failed: Connection refused (0x0000274D/10061)' }
            }
            if ($HostAddress -eq '127.0.0.2') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = '1'; StdErr = '' }
        }

        $t = Test-PgSspiLogin -Psql 'psql.exe' -Port 5432 -Addresses @('127.0.0.1') -Database 'VeeamBackup'
        Check 'sspi test: passes when every address returns 1' $t.Passed 'True'
        Check 'sspi test: one result per address'              @($t.Results).Count 1
        Check 'sspi test: result kind OK'                      $t.Results[0].Kind 'OK'
        Check 'sspi test: runs SELECT 1 on the VBR database'   $calls[0] '127.0.0.1|5432|VeeamBackup|SELECT 1;|False'

        $t = Test-PgSspiLogin -Psql 'psql.exe' -Port 5432 -Addresses @('127.0.0.1', '::1') -Database 'VeeamBackup'
        Check 'sspi test: one refused address fails the test'  $t.Passed 'False'
        Check 'sspi test: both addresses tested'               @($t.Results).Count 2
        Check 'sspi test: refused address recorded'            $t.Results[1].Address '::1'
        Check 'sspi test: refused address exit code'           $t.Results[1].ExitCode 2
        Check 'sspi test: refused address kind'                $t.Results[1].Kind 'CONNECT'
        Check 'sspi test: refused address stderr kept'         ($t.Results[1].StdErr -match '10061') 'True'

        $t = Test-PgSspiLogin -Psql 'psql.exe' -Port 5432 -Addresses @('127.0.0.2') -Database 'VeeamBackup'
        Check 'sspi test: exit 0 without 1 fails'              $t.Passed 'False'
        Check 'sspi test: exit 0 without 1 is OTHER'           $t.Results[0].Kind 'OTHER'

        $t = Test-PgSspiLogin -Psql 'psql.exe' -Port 5432 -Addresses @() -Database 'VeeamBackup'
        Check 'sspi test: no address is not a pass'            $t.Passed 'False'
    }
} catch {
    Check 'Task 11: Test-PgSspiLogin tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        Check 'path compare: forward slashes become backslashes, lower case' (ConvertTo-ComparablePath -Path 'C:/Program Files/PostgreSQL/15/data/pg_hba.conf') 'c:\program files\postgresql\15\data\pg_hba.conf'
        Check 'path compare: trailing backslash removed'          (ConvertTo-ComparablePath -Path 'C:\PG\data\') 'c:\pg\data'
        Check 'path compare: empty path stays empty'              (ConvertTo-ComparablePath -Path '') ''
        Check 'path compare: SHOW hba_file form equals edited path' (Test-SamePath -Left 'C:/Program Files/PostgreSQL/15/data/pg_hba.conf' -Right 'C:\Program Files\PostgreSQL\15\DATA\pg_hba.conf') 'True'
        Check 'path compare: dot-dot segments resolved'           (Test-SamePath -Left 'C:/PG/data/../data/pg_ident.conf' -Right 'C:\PG\data\pg_ident.conf') 'True'
        Check 'path compare: different file is not the same'      (Test-SamePath -Left 'C:/PG/data/pg_hba.conf' -Right 'C:\PG\data\pg_ident.conf') 'False'
        Check 'path compare: empty paths are not the same'        (Test-SamePath -Left '' -Right '') 'False'
    }
} catch {
    Check 'Task 11: path compare tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        $calls = New-Object System.Collections.ArrayList
        $answer = @{ Hba = '0'; Ident = '0'; HbaFile = 'C:/PG/15/data/pg_hba.conf'; IdentFile = 'C:/PG/15/data/pg_ident.conf'; FailOn = '' }
        function Invoke-PgQuery {
            param([string] $Psql, [int] $Port, [string] $HostAddress, [string] $Database, [string] $Sql, [switch] $ViaStdin)
            [void]$calls.Add($Sql)
            if ($answer.FailOn -ne '' -and $Sql -match $answer.FailOn) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR:  simulated failure' }
            }
            $out = 'unexpected query'
            switch -Regex ($Sql) {
                'pg_hba_file_rules'      { $out = $answer.Hba; break }
                'pg_ident_file_mappings' { $out = $answer.Ident; break }
                '^SHOW hba_file'         { $out = $answer.HbaFile; break }
                '^SHOW ident_file'       { $out = $answer.IdentFile; break }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = $out; StdErr = '' }
        }
        $health = { param([int] $Major) Test-PgConfigHealth -Psql 'psql.exe' -Port 5432 -Address '127.0.0.1' -Database 'VeeamBackup' -Major $Major -HbaPath 'C:\PG\15\data\pg_hba.conf' -IdentPath 'C:\PG\15\data\pg_ident.conf' }

        $h = & $health 15
        Check 'config health: clean files on PG 15 pass'         $h.Ok 'True'
        Check 'config health: PG 15 runs four queries'           $calls.Count 4
        Check 'config health: PG 15 checks pg_ident errors'      (@($calls | Where-Object { $_ -match 'pg_ident_file_mappings' }).Count) 1
        Check 'config health: hba error query'                   $calls[0] 'SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;'

        $calls.Clear()
        $h = & $health 14
        Check 'config health: clean files on PG 14 pass'         $h.Ok 'True'
        Check 'config health: PG 14 skips pg_ident_file_mappings' (@($calls | Where-Object { $_ -match 'pg_ident_file_mappings' }).Count) 0

        $answer.Hba = '2'
        $h = & $health 15
        Check 'config health: hba parse errors fail'             $h.Ok 'False'
        Check 'config health: hba error named in Detail'         ($h.Detail -match 'pg_hba_file_rules') 'True'
        $answer.Hba = '0'

        $answer.Ident = '1'
        $h = & $health 15
        Check 'config health: ident parse errors fail'           $h.Ok 'False'
        $answer.Ident = '0'

        $answer.HbaFile = 'D:/Other/data/pg_hba.conf'
        $h = & $health 15
        Check 'config health: another live hba_file fails'       $h.Ok 'False'
        Check 'config health: hba_file named in Detail'          ($h.Detail -match 'hba_file') 'True'
        $answer.HbaFile = 'C:/PG/15/data/pg_hba.conf'

        $answer.FailOn = '^SHOW ident_file'
        $h = & $health 15
        Check 'config health: failed query fails'                $h.Ok 'False'
        Check 'config health: failed query named in Detail'      ($h.Detail -match 'ident_file') 'True'
    }
} catch {
    Check 'Task 11: Test-PgConfigHealth tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        $calls = New-Object System.Collections.ArrayList
        $answer = @{
            Password = [pscustomobject]@{ ExitCode = 0; StdOut = 'SET'; StdErr = '' }
            Backends = [pscustomobject]@{ ExitCode = 0; StdOut = '[{"pid":4100,"usename":"postgres","datname":"VeeamBackup","client_addr":"127.0.0.1","start_ms":1791799200000},{"pid":4200,"usename":"pg_native_admin","datname":"postgres","client_addr":null,"start_ms":1791799260500}]'; StdErr = '' }
        }
        function Invoke-PgQuery {
            param([string] $Psql, [int] $Port, [string] $HostAddress, [string] $Database, [string] $Sql, [switch] $ViaStdin)
            [void]$calls.Add($Sql)
            if ($Sql -match 'pg_authid') { return $answer.Password }
            if ($Sql -match 'pg_stat_activity') { return $answer.Backends }
            return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'unexpected query' }
        }
        $live = { Get-PgLiveState -Psql 'psql.exe' -Port 5432 -Address '127.0.0.1' -Database 'VeeamBackup' }

        $s = & $live
        Check 'live state: Ok'                                  $s.Ok 'True'
        Check 'live state: password set'                        $s.PasswordSet 'True'
        Check 'live state: two backends'                        @($s.Backends).Count 2
        Check 'live state: backend pid'                         $s.Backends[0].Pid 4100
        Check 'live state: backend role'                        $s.Backends[0].UseName 'postgres'
        Check 'live state: backend database'                    $s.Backends[0].DatName 'VeeamBackup'
        Check 'live state: backend address'                     $s.Backends[0].ClientAddr '127.0.0.1'
        Check 'live state: backend start in UTC'                $s.Backends[0].BackendStartUtc.ToString('yyyy-MM-ddTHH:mm:ss.fff') '2026-10-12T10:00:00.000'
        Check 'live state: backend start kind is Utc'           $s.Backends[0].BackendStartUtc.Kind 'Utc'
        Check 'live state: milliseconds kept'                   $s.Backends[1].BackendStartUtc.ToString('HH:mm:ss.fff') '10:01:00.500'
        Check 'live state: null client address becomes empty'   $s.Backends[1].ClientAddr ''
        Check 'live state: password query reads only IS NULL'   (($calls[0] -match 'rolpassword IS NULL') -and ($calls[0] -notmatch 'SELECT\s+rolpassword')) 'True'
        Check 'live state: backends exclude the own session'    ($calls[1] -match "backend_type = 'client backend' AND pid <> pg_backend_pid\(\)") 'True'
        Check 'live state: no double quote in any SQL'          (@($calls | Where-Object { $_.Contains('"') }).Count) 0

        $answer.Password = [pscustomobject]@{ ExitCode = 0; StdOut = 'NONE'; StdErr = '' }
        $answer.Backends = [pscustomobject]@{ ExitCode = 0; StdOut = '[{"pid":5,"usename":"postgres","datname":"VeeamBackup","client_addr":"::1","start_ms":1791799200000}]'; StdErr = '' }
        $s = & $live
        Check 'live state: no password'                         $s.PasswordSet 'False'
        Check 'live state: a one-item JSON array is one backend' @($s.Backends).Count 1
        Check 'live state: IPv6 loopback address kept'          $s.Backends[0].ClientAddr '::1'

        $answer.Backends = [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' }
        $s = & $live
        Check 'live state: no backends is still Ok'             $s.Ok 'True'
        Check 'live state: empty backend list'                  @($s.Backends).Count 0

        $answer.Backends = [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'FATAL:  SSPI authentication failed for user "postgres"' }
        $s = & $live
        Check 'live state: failed backend query is not Ok'      $s.Ok 'False'

        $answer.Backends = [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' }
        $answer.Password = [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'FATAL:  SSPI authentication failed for user "postgres"' }
        $s = & $live
        Check 'live state: failed password query is not Ok'     $s.Ok 'False'
        Check 'live state: failure does not claim a password'   $s.PasswordSet 'False'
    }
} catch {
    Check 'Task 11: Get-PgLiveState tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        $calls = New-Object System.Collections.ArrayList
        $answer = @{ Roles = [pscustomobject]@{ ExitCode = 0; StdOut = '["pg_native_admin","zabbix"]'; StdErr = '' }; AlterExit = 0; Check = 'NONE' }
        function Invoke-PgQuery {
            param([string] $Psql, [int] $Port, [string] $HostAddress, [string] $Database, [string] $Sql, [switch] $ViaStdin)
            [void]$calls.Add([pscustomobject]@{ Sql = $Sql; ViaStdin = [bool]$ViaStdin })
            if ($Sql -match 'rolcanlogin') { return $answer.Roles }
            if ($Sql -match '^ALTER ROLE') {
                if ($answer.AlterExit -ne 0) { return [pscustomobject]@{ ExitCode = $answer.AlterExit; StdOut = ''; StdErr = 'ERROR:  permission denied' } }
                return [pscustomobject]@{ ExitCode = 0; StdOut = 'ALTER ROLE'; StdErr = '' }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = $answer.Check; StdErr = '' }
        }

        $roles = @(Get-OtherPasswordRoles -Psql 'psql.exe' -Port 5432 -Address '127.0.0.1' -Database 'VeeamBackup')
        Check 'other roles: names returned'                     ($roles -join ',') 'pg_native_admin,zabbix'
        Check 'other roles: login roles with a password, not postgres' (($calls[0].Sql -match 'rolcanlogin') -and ($calls[0].Sql -match "rolname <> 'postgres'") -and ($calls[0].Sql -match 'rolpassword IS NOT NULL')) 'True'
        Check 'other roles: the hash is never selected'         ($calls[0].Sql -notmatch 'SELECT\s+rolpassword') 'True'
        $answer.Roles = [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' }
        Check 'other roles: none'                               @(Get-OtherPasswordRoles -Psql 'psql.exe' -Port 5432 -Address '127.0.0.1' -Database 'VeeamBackup').Count 0
        $answer.Roles = [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'FATAL:  SSPI authentication failed' }
        Check 'other roles: failed query gives no names'        @(Get-OtherPasswordRoles -Psql 'psql.exe' -Port 5432 -Address '127.0.0.1' -Database 'VeeamBackup').Count 0
        Check 'other roles: failed query logs a warning'        (@($script:LogLines | Where-Object { $_ -like '`[WARN`]*other login roles*' }).Count -ge 1) 'True'

        $calls.Clear()
        $c = Clear-PostgresPassword -Psql 'psql.exe' -Port 5432 -Address '127.0.0.1' -Database 'VeeamBackup'
        Check 'clear password: Ok when the re-check says NONE'  $c.Ok 'True'
        Check 'clear password: ALTER ROLE text'                 $calls[0].Sql 'ALTER ROLE postgres PASSWORD NULL;'
        Check 'clear password: ALTER ROLE goes through stdin'   $calls[0].ViaStdin 'True'
        Check 'clear password: re-check reads only IS NULL'     ($calls[1].Sql -match 'rolpassword IS NULL') 'True'
        Check 'clear password: re-check runs with -c'           $calls[1].ViaStdin 'False'

        $answer.Check = 'SET'
        $c = Clear-PostgresPassword -Psql 'psql.exe' -Port 5432 -Address '127.0.0.1' -Database 'VeeamBackup'
        Check 'clear password: still set fails'                 $c.Ok 'False'
        Check 'clear password: still set named in Detail'       ($c.Detail -match 'still set') 'True'

        $answer.Check = 'NONE'
        $answer.AlterExit = 1
        $calls.Clear()
        $c = Clear-PostgresPassword -Psql 'psql.exe' -Port 5432 -Address '127.0.0.1' -Database 'VeeamBackup'
        Check 'clear password: failed ALTER fails'              $c.Ok 'False'
        Check 'clear password: failed ALTER named in Detail'    ($c.Detail -match 'ALTER ROLE failed') 'True'
        Check 'clear password: no re-check after a failed ALTER' $calls.Count 1
    }
} catch {
    Check 'Task 11: password role tests ran to the end' $_.Exception.Message ''
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: the earlier checks still PASS and seven new lines FAIL, one per group, for example:
`  FAIL  Task 11: Invoke-PgQuery tests ran to the end  expected '' got 'The term 'Invoke-PgQuery' is not recognized as the name of a cmdlet, function, script file, or operable program. ...'`
The other six name `Get-PsqlFailureKind`, `Test-PgSspiLogin`, `ConvertTo-ComparablePath`, `Test-PgConfigHealth`, `Get-PgLiveState` and `Get-OtherPasswordRoles`. The last line is `RESULT: <earlier total> passed, 7 failed` and the exit code is 1.

- [ ] **Step 3: Implement**

Insert this block in `Invoke-VbrStandardise.ps1` directly above the line `#endregion Psql`.

```powershell
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: <n> passed, 0 failed`, where n is the previous total plus 104 (the new Task 11 checks), and exit code 0. On an elevated prompt on English Windows without PostgreSQL or VBR that is `RESULT: 949 passed, 0 failed`.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add psql runner, SSPI login test and live PostgreSQL queries" -m "Invoke-PgQuery runs psql with -X -w, PGPASSFILE=nul and a cleared libpq environment so only SSPI can log in, and puts the old variables back afterwards. The SSPI test, config health check, live state, other password roles and password clear build on it and read only booleans from pg_authid." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: DbAuth state and blockers

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region State)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Get-CfgValue -Object -Name -Default` (Task 1), `Get-DbHostClass -HostName -LocalNames` (Task 4).
- Produces: `Test-VbrBackendsOk`, `Get-DbAuthState`, `Select-RemoteClients`, `Get-EstablishedRemoteClients`, `Get-ConsumerIssues`.

Notes for the engineer:
- Spec 7.4 (`DbAuth`) and 7.5 (blockers). These are pure decisions over objects that Tasks 4 and 11 produce, plus one thin wrapper over `Get-NetTCPConnection`.
- Role names are compared case-sensitively (`-cne 'postgres'`), because PostgreSQL role names are case-sensitive. Database names are compared case-insensitively, as the spec says.
- `Get-ConsumerIssues` returns at most one issue per code, with every source listed in `Detail`. It fails closed: an Enterprise Manager or Entra ID setting with a password and an empty host or port counts as "this instance".
- Client addresses that belong to this server (its own IPs, from `LocalNames`) are VBR's own sessions only when `SqlHostName` is a local, non-loopback name (the `DB_HOST_NOT_LOCAL` case that Path B fixes). Only then are they not counted as remote. With a loopback `SqlHostName`, VBR never connects from those addresses, so a session from them is another client that the loopback-only `pg_hba.conf` would cut off, and it counts.

- [ ] **Step 1: Write the failing tests**

Insert this block in `Test-VbrStandardise.ps1` directly above the line `# ===================== RESULT =====================`.

```powershell
# --- Task 12: DbAuth state and blockers ---
try {
    & {
        $be = { param($Db, $User, $Addr) [pscustomobject]@{ Pid = 1; UseName = $User; DatName = $Db; ClientAddr = $Addr; BackendStartUtc = [datetime]::UtcNow } }
        $good = @(
            (& $be 'VeeamBackup' 'postgres' '127.0.0.1'),
            (& $be 'veeambackup' 'postgres' '::1'),
            (& $be 'postgres' 'pg_native_admin' '192.168.1.9')
        )
        Check 'vbr backends: loopback postgres sessions are OK'      (Test-VbrBackendsOk -Backends $good -Database 'VeeamBackup') 'True'
        Check 'vbr backends: other role on the VBR database fails'   (Test-VbrBackendsOk -Backends ($good + @(& $be 'VeeamBackup' 'pg_native_admin' '127.0.0.1')) -Database 'VeeamBackup') 'False'
        Check 'vbr backends: role name is case-sensitive'            (Test-VbrBackendsOk -Backends @(& $be 'VeeamBackup' 'Postgres' '127.0.0.1') -Database 'VeeamBackup') 'False'
        Check 'vbr backends: LAN address on the VBR database fails'  (Test-VbrBackendsOk -Backends ($good + @(& $be 'VeeamBackup' 'postgres' '192.168.1.20')) -Database 'VeeamBackup') 'False'
        Check 'vbr backends: missing address on the VBR database fails' (Test-VbrBackendsOk -Backends @(& $be 'VeeamBackup' 'postgres' '') -Database 'VeeamBackup') 'False'
        Check 'vbr backends: no sessions is OK'                      (Test-VbrBackendsOk -Backends @() -Database 'VeeamBackup') 'True'
        Check 'vbr backends: null list is OK'                        (Test-VbrBackendsOk -Backends $null -Database 'VeeamBackup') 'True'
    }
} catch {
    Check 'Task 12: Test-VbrBackendsOk tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        Check 'db auth: registry NATIVE wins'                  (Get-DbAuthState -RegistryAuth 'NATIVE'  -SspiPassed $true  -FirstMatchOk $true  -VbrBackendsOk $true) 'NATIVE'
        Check 'db auth: registry NATIVE without SSPI'          (Get-DbAuthState -RegistryAuth 'NATIVE'  -SspiPassed $false -FirstMatchOk $false -VbrBackendsOk $false) 'NATIVE'
        Check 'db auth: WINDOWS when all checks pass'          (Get-DbAuthState -RegistryAuth 'WINDOWS' -SspiPassed $true  -FirstMatchOk $true  -VbrBackendsOk $true) 'WINDOWS'
        Check 'db auth: SSPI failure is UNKNOWN'               (Get-DbAuthState -RegistryAuth 'WINDOWS' -SspiPassed $false -FirstMatchOk $true  -VbrBackendsOk $true) 'UNKNOWN'
        Check 'db auth: first hba match not sspi is UNKNOWN'   (Get-DbAuthState -RegistryAuth 'WINDOWS' -SspiPassed $true  -FirstMatchOk $false -VbrBackendsOk $true) 'UNKNOWN'
        Check 'db auth: odd VBR backends is UNKNOWN'           (Get-DbAuthState -RegistryAuth 'WINDOWS' -SspiPassed $true  -FirstMatchOk $true  -VbrBackendsOk $false) 'UNKNOWN'
        Check 'db auth: unknown registry value is UNKNOWN'     (Get-DbAuthState -RegistryAuth ''        -SspiPassed $true  -FirstMatchOk $true  -VbrBackendsOk $true) 'UNKNOWN'
    }
} catch {
    Check 'Task 12: Get-DbAuthState tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        $tcp = { param($Port, $Remote, $State) [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = $Port; RemoteAddress = $Remote; RemotePort = 50000; State = $State } }
        $connections = @(
            (& $tcp 5432 '192.168.1.50' 'Established'),
            (& $tcp 5432 '127.0.0.1' 'Established'),
            (& $tcp 5432 '::1' 'Established'),
            (& $tcp 5432 '::ffff:127.0.0.1' 'Established'),
            (& $tcp 5432 '0.0.0.0' 'Listen'),
            (& $tcp 5432 '192.168.1.51' 'TimeWait'),
            (& $tcp 9392 '192.168.1.52' 'Established'),
            (& $tcp 5432 '192.168.1.50' 'Established'),
            (& $tcp 5432 'fe80::5%12' 'Established')
        )
        Check 'remote clients: only established, this port, not loopback, once each' (@(Select-RemoteClients -Connections $connections -Port 5432) -join ',') '192.168.1.50,fe80::5%12'
        Check 'remote clients: none'                 @(Select-RemoteClients -Connections @() -Port 5432).Count 0
        Check 'remote clients: other port only'      @(Select-RemoteClients -Connections @(& $tcp 5433 '10.0.0.1' 'Established') -Port 5432).Count 0
    }
} catch {
    Check 'Task 12: Select-RemoteClients tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        $mode = @{ Value = 'list' }
        $seen = New-Object System.Collections.ArrayList
        function Get-NetTCPConnection {
            [CmdletBinding()] param($State, $LocalPort)
            [void]$seen.Add("$State|$LocalPort")
            if ($mode.Value -eq 'none') {
                Write-Error -Message "No MSFT_NetTCPConnection objects found with property 'LocalPort' equal to '$LocalPort'." -Category ObjectNotFound
                return
            }
            if ($mode.Value -eq 'broken') {
                Write-Error -Message 'Access denied' -Category PermissionDenied
                return
            }
            [pscustomobject]@{ LocalPort = 5432; RemoteAddress = '10.0.0.9'; State = 'Established' }
            [pscustomobject]@{ LocalPort = 5432; RemoteAddress = '127.0.0.1'; State = 'Established' }
        }
        Check 'tcp clients: remote address from Get-NetTCPConnection' (@(Get-EstablishedRemoteClients -Port 5432) -join ',') '10.0.0.9'
        Check 'tcp clients: asks for established connections on the port' $seen[0] 'Established|5432'
        $mode.Value = 'none'
        Check 'tcp clients: no connection is not an error'   @(Get-EstablishedRemoteClients -Port 5432).Count 0
        $mode.Value = 'broken'
        Throws 'tcp clients: other errors are not hidden'    { Get-EstablishedRemoteClients -Port 5432 }
    }
} catch {
    Check 'Task 12: Get-EstablishedRemoteClients tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        $localNames = @('VBR01', 'vbr01.corp.local', '192.168.1.10', 'fe80::10%4')
        $db = {
            param([string] $HostName = '127.0.0.1', [string] $EntraHost = '', $EntraPort = $null, [bool] $EntraPassword = $false)
            [pscustomobject]@{
                RootKey = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication'; KeyPath = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication\DatabaseConfigurations\PostgreSql'
                ActiveConfiguration = 'PostgreSql'; HostName = $HostName; Port = 5432; DatabaseName = 'VeeamBackup'; UserName = ''; PasswordSet = $false
                WindowsAuthRole = 'postgres'; EntraIdHost = $EntraHost; EntraIdPort = $EntraPort; EntraIdPasswordSet = $EntraPassword
            }
        }
        $em = { param([string] $Active, [string] $HostName, $Port, [bool] $Password) [pscustomobject]@{ ActiveConfiguration = $Active; HostName = $HostName; Port = $Port; PasswordSet = $Password } }
        $be = { param($Db, $User, $Addr) [pscustomobject]@{ Pid = 1; UseName = $User; DatName = $Db; ClientAddr = $Addr; BackendStartUtc = [datetime]::UtcNow } }
        $vbrOnly = @((& $be 'VeeamBackup' 'postgres' '127.0.0.1'), (& $be 'postgres' 'postgres' '::1'))
        $consumers = { param($DbConfig, $EmConfig, $Backends, $Remote) Get-ConsumerIssues -DbConfig $DbConfig -EmConfig $EmConfig -Backends $Backends -RemoteClients $Remote -LocalNames $localNames }

        $r = @(& $consumers (& $db) $null $vbrOnly @())
        Check 'consumers: clean server has none'                  $r.Count 0

        $r = @(& $consumers (& $db) (& $em 'PostgreSql' 'localhost' 5432 $true) $vbrOnly @())
        Check 'consumers: local EM with a password'               ($r | ForEach-Object { $_.Code }) 'PG_PASSWORD_CONSUMER'
        Check 'consumers: EM named in Detail'                     ($r[0].Detail -match 'Enterprise Manager') 'True'
        Check 'consumers: password consumer has an action'        ($r[0].Action -ne '') 'True'
        Check 'consumers: EM on its own server is not ours'       @(& $consumers (& $db) (& $em 'PostgreSql' 'sql02.corp.local' 5432 $true) $vbrOnly @()).Count 0
        Check 'consumers: EM on MsSql is not ours'                @(& $consumers (& $db) (& $em 'MsSql' 'localhost' 5432 $true) $vbrOnly @()).Count 0
        Check 'consumers: EM on another port is not ours'         @(& $consumers (& $db) (& $em 'PostgreSql' 'VBR01' 5433 $true) $vbrOnly @()).Count 0
        Check 'consumers: EM with Windows auth is fine'           @(& $consumers (& $db) (& $em 'PostgreSql' 'localhost' 5432 $false) $vbrOnly @()).Count 0
        Check 'consumers: EM by server IP with a password'        (@(& $consumers (& $db) (& $em 'PostgreSql' '192.168.1.10' 5432 $true) $vbrOnly @()) | ForEach-Object { $_.Code }) 'PG_PASSWORD_CONSUMER'

        $r = @(& $consumers (& $db -EntraHost 'localhost' -EntraPort 5432 -EntraPassword $true) $null $vbrOnly @())
        Check 'consumers: Entra ID repository with a password'    ($r | ForEach-Object { $_.Code }) 'PG_PASSWORD_CONSUMER'
        Check 'consumers: Entra ID named in Detail'               ($r[0].Detail -match 'Entra ID') 'True'
        Check 'consumers: Entra ID with no host or port counts'   @(& $consumers (& $db -EntraPassword $true) $null $vbrOnly @()).Count 1
        Check 'consumers: Entra ID on another server is not ours' @(& $consumers (& $db -EntraHost 'pg02.corp.local' -EntraPort 5432 -EntraPassword $true) $null $vbrOnly @()).Count 0

        $r = @(& $consumers (& $db) $null ($vbrOnly + @(& $be 'VeeamBackup' 'pg_native_admin' '127.0.0.1')) @())
        Check 'consumers: session as another role'                ($r | ForEach-Object { $_.Code }) 'PG_PASSWORD_CONSUMER'
        Check 'consumers: other role named in Detail'             ($r[0].Detail -match 'pg_native_admin') 'True'

        $r = @(& $consumers (& $db) $null ($vbrOnly + @(& $be 'VeeamBackup' 'postgres' '192.168.1.77')) @())
        Check 'consumers: session from a LAN address'             ($r | ForEach-Object { $_.Code }) 'PG_REMOTE_CONSUMER'
        Check 'consumers: LAN address named in Detail'            ($r[0].Detail -match '192\.168\.1\.77') 'True'
        Check 'consumers: remote action text'                     $r[0].Action 'Move or stop the remote client, then re-run'

        $r = @(& $consumers (& $db) $null $null @('10.1.1.1'))
        Check 'consumers: TCP client without SSPI'                ($r | ForEach-Object { $_.Code }) 'PG_REMOTE_CONSUMER'
        Check 'consumers: TCP client named in Detail'             ($r[0].Detail -match '10\.1\.1\.1') 'True'
        Check 'consumers: no SSPI and no TCP client'              @(& $consumers (& $db) $null $null @()).Count 0

        Check 'consumers: own IP is VBR when SqlHostName is the server name' @(& $consumers (& $db -HostName 'VBR01') $null @(& $be 'VeeamBackup' 'postgres' '192.168.1.10') @('192.168.1.10')).Count 0
        $r = @(& $consumers (& $db) $null $vbrOnly @('192.168.1.10'))
        Check 'consumers: own IP is another client when VBR uses loopback' ($r | ForEach-Object { $_.Code }) 'PG_REMOTE_CONSUMER'

        $r = @(& $consumers (& $db) (& $em 'PostgreSql' 'localhost' 5432 $true) ($vbrOnly + @(& $be 'Reports' 'zabbix' '10.2.2.2')) @('10.3.3.3'))
        Check 'consumers: password and remote issues together'    (($r | ForEach-Object { $_.Code }) -join ',') 'PG_PASSWORD_CONSUMER,PG_REMOTE_CONSUMER'
        Check 'consumers: every remote address listed'            (($r[1].Detail -match '10\.2\.2\.2') -and ($r[1].Detail -match '10\.3\.3\.3')) 'True'
        Check 'consumers: every password source listed'          (($r[0].Detail -match 'Enterprise Manager') -and ($r[0].Detail -match 'zabbix')) 'True'
    }
} catch {
    Check 'Task 12: Get-ConsumerIssues tests ran to the end' $_.Exception.Message ''
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: the earlier checks still PASS and five new lines FAIL, one per group, for example:
`  FAIL  Task 12: Test-VbrBackendsOk tests ran to the end  expected '' got 'The term 'Test-VbrBackendsOk' is not recognized as the name of a cmdlet, function, script file, or operable program. ...'`
The other four name `Get-DbAuthState`, `Select-RemoteClients`, `Get-EstablishedRemoteClients` and `Get-ConsumerIssues`. The last line is `RESULT: <earlier total> passed, 5 failed` and the exit code is 1.

- [ ] **Step 3: Implement**

Insert this block in `Invoke-VbrStandardise.ps1` directly above the line `#endregion State`.

```powershell
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: <n> passed, 0 failed`, where n is the previous total plus 47 (the new Task 12 checks), and exit code 0. On an elevated prompt on English Windows without PostgreSQL or VBR that is `RESULT: 996 passed, 0 failed`.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add DbAuth decision and password and remote consumer blockers" -m "DbAuth is WINDOWS only when the registry, the SSPI test, the first pg_hba match and every VBR session agree. Enterprise Manager, the Entra ID repository, sessions as other roles and clients from other addresses block any database change (spec 7.4 and 7.5)." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Idle gate and bounded service stop/start

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region Services)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Write-Log`, `Format-ShortText` (Task 1)
- Produces: `Get-BusyVeeamWork`, `Get-VeeamServiceSnapshot`, `Get-StopSet`, `Get-ExternalDependents`, `Get-StartOrder`, `Stop-ServicesBounded`, `Start-ServicesBounded`, `Test-ServiceStaysRunning`

Spec: 7.6 Path B steps 2, 3, 5 and 9, rollback steps 1, 4 and 5; 7.11; 7.12. The stop order and the dependency-ordered start are adapted from the updater (`Get-VeeamServiceStartOrder` and its `$stopOrder`). The updater's set-to-Disabled step (`Disable-VeeamServiceStartup`, `Set-ServiceStartupTypeExact`) is NOT copied: nothing in this task changes a startup type.

Notes for this task:
- "Running" in the stop set and in the external-dependents check means any status other than `Stopped` (`StartPending`, `Paused` and `StopPending` too): such a service can still hold a database connection, so it must be down before the switch and started again afterwards.
- `Stop-Service` without `-Force` refuses to stop a service while one of its dependents is not yet `Stopped`. The alphabetical stop order puts `VeeamBackupSvc` before its dependents, so `Stop-ServicesBounded` asks again on every 2-second poll for each service that is up and not already `StopPending`. This is the updater's multi-pass stop, bounded by `TimeoutSec`.
- `Get-ExternalDependents` reads `DependsOn` and, when an object has no `DependsOn`, `ServicesDependedOn`, so Task 17 can pass `@(Get-Service)` directly.
- `Start-ServicesBounded` gets each `ServiceController` from `Get-Service` (which returns `System.ServiceProcess.ServiceController` objects), so no assembly has to be loaded, and the tests mock `Get-Service` instead of `New-Object`.
- Mocks are functions defined inside `& { }` child scopes. A mock looks up variables through its CALLER's scope first, so a mock state variable named like a local in the function under test (for example `$status` in `Stop-ServicesBounded`) silently resolves to that local. Every mock state variable in these tests has the `t13` prefix for that reason. Hashtable state uses the key `N`, never `Count`, because `$h.Count` is the entry count.

- [ ] **Step 1: Write the failing tests**

Insert this block in `Test-VbrStandardise.ps1` directly above the line `# ===================== RESULT =====================`. It uses only fake objects and mocked `Get-Service`, `Stop-Service` and `Start-Sleep`; the only real calls are a read-only `Get-Service` of `Veeam*` and of a service name that does not exist. Two checks really sleep for about one second each.

```powershell
# --- Task 13: Idle gate and bounded service stop/start ---

# Get-BusyVeeamWork: process names compare without .exe, case-insensitively.
$t13Now = Get-Date -Year 2026 -Month 10 -Day 12 -Hour 12 -Minute 0 -Second 0
$t13Procs = @(
    [pscustomobject]@{ Name = 'Veeam.Backup.Manager'; StartTime = $t13Now.AddMinutes(-30) }
    [pscustomobject]@{ Name = 'VEEAMAGENT.EXE';       StartTime = $t13Now.AddHours(-7) }
    [pscustomobject]@{ Name = 'Veeam.Exchange.Explorer'; StartTime = $t13Now.AddMinutes(-5) }
    [pscustomobject]@{ Name = 'Veeam.Backup.Shell';   StartTime = $t13Now.AddDays(-3) }
    [pscustomobject]@{ Name = 'Veeam.Backup.Service'; StartTime = $t13Now.AddDays(-30) }
    [pscustomobject]@{ Name = 'notepad';              StartTime = $t13Now.AddDays(-1) }
)
$t13Busy = Get-BusyVeeamWork -Processes $t13Procs -Now $t13Now -PersistentHours 6
Check 'T13 busy: manager, agent and explorer are busy' $t13Busy.Busy $true
Check 'T13 busy: names without .exe, sorted, console and services ignored' (@($t13Busy.Names) -join ',') 'Veeam.Backup.Manager,Veeam.Exchange.Explorer,VEEAMAGENT'
Check 'T13 busy: oldest busy process over 6 h is persistent' $t13Busy.Persistent $true
$t13Young = Get-BusyVeeamWork -Processes @($t13Procs[0], $t13Procs[2], $t13Procs[3]) -Now $t13Now -PersistentHours 6
Check 'T13 busy: young processes are busy' $t13Young.Busy $true
Check 'T13 busy: young processes are not persistent' $t13Young.Persistent $false
$t13Edge = Get-BusyVeeamWork -Processes @([pscustomobject]@{ Name = 'VeeamAgent'; StartTime = $t13Now.AddHours(-6) }) -Now $t13Now -PersistentHours 6
Check 'T13 busy: exactly 6 h is not longer than 6 h' $t13Edge.Persistent $false
$t13NoStart = Get-BusyVeeamWork -Processes @([pscustomobject]@{ Name = 'Veeam.Backup.Manager.exe' }, [pscustomobject]@{ Name = 'VeeamAgent'; StartTime = $null }) -Now $t13Now -PersistentHours 6
Check 'T13 busy: unknown start time is busy' $t13NoStart.Busy $true
Check 'T13 busy: unknown start time is never persistent' $t13NoStart.Persistent $false
Check 'T13 busy: duplicate names reported once' (@((Get-BusyVeeamWork -Processes @($t13Procs[0], $t13Procs[0]) -Now $t13Now -PersistentHours 6).Names).Count) 1
$t13Idle = Get-BusyVeeamWork -Processes @($t13Procs[3], $t13Procs[4], $t13Procs[5]) -Now $t13Now -PersistentHours 6
Check 'T13 busy: console and services only is idle' $t13Idle.Busy $false
Check 'T13 busy: idle has no names' (@($t13Idle.Names).Count) 0
$t13Empty = Get-BusyVeeamWork -Processes @() -Now $t13Now -PersistentHours 6
Check 'T13 busy: no processes is idle' "$($t13Empty.Busy)/$($t13Empty.Persistent)" 'False/False'
Check 'T13 busy: null process list is idle' (Get-BusyVeeamWork -Processes $null -Now $t13Now -PersistentHours 6).Busy $false

# Get-VeeamServiceSnapshot: shape, from a mocked Get-Service.
& {
    $t13Calls = New-Object System.Collections.ArrayList
    function Get-Service {
        [CmdletBinding()] param([Parameter(Position = 0)][string[]] $Name)
        [void]$t13Calls.Add(($Name -join ','))
        [pscustomobject]@{ Name = 'VeeamBackupSvc'; Status = 'Running'; StartType = 'Automatic'
            ServicesDependedOn = @([pscustomobject]@{ Name = 'RpcSs' }, [pscustomobject]@{ Name = 'Winmgmt' })
            DependentServices = @([pscustomobject]@{ Name = 'VeeamBrokerSvc' }) }
        [pscustomobject]@{ Name = 'VeeamBrokerSvc'; Status = 'Stopped'; StartType = 'Manual'
            ServicesDependedOn = @([pscustomobject]@{ Name = 'VeeamBackupSvc' }); DependentServices = @() }
        [pscustomobject]@{ Name = 'VeeamOldSvc'; Status = 'Running' }
        [pscustomobject]@{ Name = 'NotVeeam'; Status = 'Running'; StartType = 'Automatic'; ServicesDependedOn = @(); DependentServices = @() }
    }
    $t13SnapOut = @(Get-VeeamServiceSnapshot)
    Check 'T13 snapshot: asks for Veeam*' ($t13Calls -join '|') 'Veeam*'
    Check 'T13 snapshot: only Veeam services' (@($t13SnapOut | ForEach-Object { $_.Name }) -join ',') 'VeeamBackupSvc,VeeamBrokerSvc,VeeamOldSvc'
    Check 'T13 snapshot: status is a string' $t13SnapOut[0].Status 'Running'
    Check 'T13 snapshot: start type kept' "$($t13SnapOut[0].StartType)/$($t13SnapOut[1].StartType)" 'Automatic/Manual'
    Check 'T13 snapshot: DependsOn names' (@($t13SnapOut[0].DependsOn) -join ',') 'RpcSs,Winmgmt'
    Check 'T13 snapshot: Dependents names' (@($t13SnapOut[0].Dependents) -join ',') 'VeeamBrokerSvc'
    Check 'T13 snapshot: missing members tolerated' "$($t13SnapOut[2].StartType)/$(@($t13SnapOut[2].DependsOn).Count)/$(@($t13SnapOut[2].Dependents).Count)" 'Unknown/0/0'
}
& {
    function Get-Service { [CmdletBinding()] param([Parameter(Position = 0)][string[]] $Name) throw 'Cannot open Service Control Manager on computer .' }
    Throws 'T13 snapshot: a failed enumeration throws' { Get-VeeamServiceSnapshot }
}
$t13RealOk = $true
try { $null = @(Get-VeeamServiceSnapshot) } catch { $t13RealOk = $false }
Check 'T13 snapshot: runs read-only on this machine' $t13RealOk $true

# Get-StopSet: every service that is not Stopped, alphabetical (ordinal), Management Agent last.
$t13Snap = @(
    [pscustomobject]@{ Name = 'VeeamWebSvc';             Status = 'Running' }
    [pscustomobject]@{ Name = 'VeeamManagementAgentSvc'; Status = 'Running' }
    [pscustomobject]@{ Name = 'VeeamBackupSvc';          Status = 'Running' }
    [pscustomobject]@{ Name = 'VeeamNFSSvc';             Status = 'Stopped' }
    [pscustomobject]@{ Name = 'Veeam.Something.Svc';     Status = 'StartPending' }
    [pscustomobject]@{ Name = 'VeeamBrokerSvc';          Status = 'StopPending' }
    [pscustomobject]@{ Name = 'VeeamBackupSvc';          Status = 'Running' }
)
Check 'T13 stop set: order' (@(Get-StopSet -Snapshot $t13Snap) -join ',') 'Veeam.Something.Svc,VeeamBackupSvc,VeeamBrokerSvc,VeeamWebSvc,VeeamManagementAgentSvc'
Check 'T13 stop set: empty snapshot' (@(Get-StopSet -Snapshot @()).Count) 0
Check 'T13 stop set: all stopped' (@(Get-StopSet -Snapshot @([pscustomobject]@{ Name = 'VeeamX'; Status = 'Stopped' })).Count) 0

# Get-ExternalDependents: running, outside the set, direct dependency on a member.
$t13All = @(
    [pscustomobject]@{ Name = 'VeeamBackupSvc'; Status = 'Running'; DependsOn = @('RpcSs') }
    [pscustomobject]@{ Name = 'VeeamBrokerSvc'; Status = 'Running'; DependsOn = @('VeeamBackupSvc') }
    [pscustomobject]@{ Name = 'ThirdPartySvc';  Status = 'Running'; DependsOn = @('RpcSs', 'VeeamBackupSvc') }
    [pscustomobject]@{ Name = 'lowercase-dep';  Status = 'StartPending'; DependsOn = @('veeambrokersvc') }
    [pscustomobject]@{ Name = 'StoppedDep';     Status = 'Stopped'; DependsOn = @('VeeamBackupSvc') }
    [pscustomobject]@{ Name = 'Unrelated';      Status = 'Running'; DependsOn = @('RpcSs') }
    [pscustomobject]@{ Name = 'NoDepsMember';   Status = 'Running'; DependsOn = $null }
    [pscustomobject]@{ Name = 'ScLikeSvc';      Status = 'Running'; ServicesDependedOn = @([pscustomobject]@{ Name = 'VeeamBrokerSvc' }) }
)
Check 'T13 external: found, sorted' (@(Get-ExternalDependents -StopSet @('VeeamBackupSvc', 'VeeamBrokerSvc') -AllServices $t13All) -join ',') 'lowercase-dep,ScLikeSvc,ThirdPartySvc'
Check 'T13 external: empty stop set' (@(Get-ExternalDependents -StopSet @() -AllServices $t13All).Count) 0
Check 'T13 external: no services' (@(Get-ExternalDependents -StopSet @('VeeamBackupSvc') -AllServices @()).Count) 0

# Get-StartOrder: real VBR 13.0.1 dependency data, listed in Get-Service order.
$t13Vbr = @(
    [pscustomobject]@{ Name = 'VeeamAHVSvc';          DependsOn = @('RpcSs', 'Winmgmt') }
    [pscustomobject]@{ Name = 'VeeamBackupCdpSvc';    DependsOn = @('RpcSs', 'VeeamBackupSvc') }
    [pscustomobject]@{ Name = 'VeeamBackupRESTSvc';   DependsOn = @('Winmgmt', 'RpcSs', 'VeeamBackupSvc') }
    [pscustomobject]@{ Name = 'VeeamBackupSvc';       DependsOn = @('RpcSs', 'Winmgmt') }
    [pscustomobject]@{ Name = 'VeeamBrokerSvc';       DependsOn = @('RpcSs', 'VeeamBackupSvc') }
    [pscustomobject]@{ Name = 'VeeamCloudSvc';        DependsOn = @('RpcSs', 'VeeamBackupSvc') }
    [pscustomobject]@{ Name = 'VeeamDataAnalyzerSvc'; DependsOn = @('RpcSs', 'VeeamBackupSvc') }
    [pscustomobject]@{ Name = 'VeeamGCPSvc';          DependsOn = @() }
    [pscustomobject]@{ Name = 'VeeamTransportSvc';    DependsOn = @('RpcSs', 'Winmgmt') }
    [pscustomobject]@{ Name = 'VeeamWebSvc';          DependsOn = @('VeeamBackupRESTSvc', 'RpcSs', 'VeeamBackupSvc') }
)
$t13AllNames = @($t13Vbr | ForEach-Object { $_.Name })
Check 'T13 start order: dependencies first, waves alphabetical' (@(Get-StartOrder -Snapshot $t13Vbr -Names $t13AllNames) -join ',') 'VeeamAHVSvc,VeeamBackupSvc,VeeamGCPSvc,VeeamTransportSvc,VeeamBackupCdpSvc,VeeamBackupRESTSvc,VeeamBrokerSvc,VeeamCloudSvc,VeeamDataAnalyzerSvc,VeeamWebSvc'
Check 'T13 start order: only the given names' (@(Get-StartOrder -Snapshot $t13Vbr -Names @('VeeamWebSvc', 'VeeamBackupSvc')) -join ',') 'VeeamBackupSvc,VeeamWebSvc'
$t13Cycle = @(
    [pscustomobject]@{ Name = 'B'; DependsOn = @('A') }
    [pscustomobject]@{ Name = 'A'; DependsOn = @('B') }
    [pscustomobject]@{ Name = 'C'; DependsOn = @() }
)
Check 'T13 start order: cycle kept, free one first' (@(Get-StartOrder -Snapshot $t13Cycle -Names @('B', 'A', 'C')) -join ',') 'C,A,B'
Check 'T13 start order: missing DependsOn and unknown name tolerated' (@(Get-StartOrder -Snapshot @([pscustomobject]@{ Name = 'X' }) -Names @('Y', 'X')) -join ',') 'X,Y'
Check 'T13 start order: duplicate names once' (@(Get-StartOrder -Snapshot $t13Vbr -Names @('VeeamGCPSvc', 'veeamgcpsvc')) -join ',') 'VeeamGCPSvc'
Check 'T13 start order: empty' (@(Get-StartOrder -Snapshot $t13Vbr -Names @()).Count) 0

# Stop-ServicesBounded: -NoWait, never -Force, retries while a dependent is still stopping.
& {
    $t13State = @{ VeeamBackupSvc = 'Running'; VeeamBrokerSvc = 'Running' }
    $t13Deps = @{ VeeamBackupSvc = @('VeeamBrokerSvc') }
    $t13Stops = New-Object System.Collections.ArrayList
    $t13Sleeps = New-Object System.Collections.ArrayList
    function Get-Service {
        [CmdletBinding()] param([Parameter(Position = 0)][string[]] $Name)
        $n = $Name[0]
        if (-not $t13State.ContainsKey($n)) { return }
        if ($t13State[$n] -eq 'StopPending') { $t13State[$n] = 'Stopped' }
        [pscustomobject]@{ Name = $n; Status = $t13State[$n] }
    }
    function Stop-Service {
        [CmdletBinding()] param([string] $Name, [switch] $NoWait, [switch] $Force)
        [void]$t13Stops.Add([pscustomobject]@{ Name = $Name; NoWait = $NoWait.IsPresent; Force = $Force.IsPresent })
        foreach ($d in @($t13Deps[$Name] | Where-Object { $_ })) {
            if ($t13State[$d] -ne 'Stopped') { throw "Cannot stop service '$Name' because it has dependent services." }
        }
        $t13State[$Name] = 'StopPending'
    }
    function Start-Sleep { [CmdletBinding()] param([int] $Seconds, [int] $Milliseconds) [void]$t13Sleeps.Add($Milliseconds) }
    $t13R = Stop-ServicesBounded -Names @('VeeamBackupSvc', 'VeeamBrokerSvc') -TimeoutSec 30
    Check 'T13 stop: Ok' $t13R.Ok $true
    Check 'T13 stop: both stopped' (@($t13R.Stopped) -join ',') 'VeeamBackupSvc,VeeamBrokerSvc'
    Check 'T13 stop: none left' (@($t13R.NotStopped).Count) 0
    Check 'T13 stop: every call uses -NoWait' (@($t13Stops | Where-Object { -not $_.NoWait }).Count) 0
    Check 'T13 stop: no call uses -Force' (@($t13Stops | Where-Object { $_.Force }).Count) 0
    Check 'T13 stop: parent asked again until its dependent stopped' (@($t13Stops | Where-Object { $_.Name -eq 'VeeamBackupSvc' }).Count) 3
    Check 'T13 stop: polls every 2 s' $t13Sleeps[0] 2000
}
& {
    $t13State = @{ VeeamAaaSvc = 'Running'; VeeamStuckSvc = 'StopPending' }
    $t13Stops = New-Object System.Collections.ArrayList
    function Get-Service {
        [CmdletBinding()] param([Parameter(Position = 0)][string[]] $Name)
        $n = $Name[0]
        if (-not $t13State.ContainsKey($n)) { return }
        if ($t13State[$n] -eq 'StopPending' -and $n -ne 'VeeamStuckSvc') { $t13State[$n] = 'Stopped' }
        [pscustomobject]@{ Name = $n; Status = $t13State[$n] }
    }
    function Stop-Service {
        [CmdletBinding()] param([string] $Name, [switch] $NoWait, [switch] $Force)
        [void]$t13Stops.Add([pscustomobject]@{ Name = $Name; NoWait = $NoWait.IsPresent; Force = $Force.IsPresent })
        $t13State[$Name] = 'StopPending'
    }
    function Start-Sleep { [CmdletBinding()] param([int] $Seconds, [int] $Milliseconds) Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 200 }
    $t13LogMark = $script:LogLines.Count
    $t13Clock = [System.Diagnostics.Stopwatch]::StartNew()
    $t13R = Stop-ServicesBounded -Names @('VeeamAaaSvc', 'VeeamStuckSvc', 'VeeamGoneSvc') -TimeoutSec 1
    $t13Clock.Stop()
    Check 'T13 stop timeout: not Ok' $t13R.Ok $false
    Check 'T13 stop timeout: the normal one stopped' (@($t13R.Stopped) -join ',') 'VeeamAaaSvc'
    Check 'T13 stop timeout: stuck and missing are NotStopped' (@($t13R.NotStopped) -join ',') 'VeeamStuckSvc,VeeamGoneSvc'
    Check 'T13 stop timeout: a StopPending service is not asked again' (@($t13Stops | Where-Object { $_.Name -eq 'VeeamStuckSvc' }).Count) 0
    Check 'T13 stop timeout: waited about TimeoutSec' ($t13Clock.Elapsed.TotalSeconds -ge 1 -and $t13Clock.Elapsed.TotalSeconds -lt 10) $true
    Check 'T13 stop timeout: warning names the stuck service' (@($script:LogLines | Select-Object -Skip $t13LogMark | Where-Object { $_ -like '`[WARN`]*VeeamStuckSvc=StopPending*' }).Count) 1
}
& {
    $t13Stops = New-Object System.Collections.ArrayList
    function Stop-Service { [CmdletBinding()] param([string] $Name, [switch] $NoWait, [switch] $Force) [void]$t13Stops.Add($Name) }
    $t13R = Stop-ServicesBounded -Names @() -TimeoutSec 5
    Check 'T13 stop: empty list is Ok' "$($t13R.Ok)/$(@($t13R.Stopped).Count)/$(@($t13R.NotStopped).Count)/$($t13Stops.Count)" 'True/0/0/0'
}
$t13StopFn = $ScriptAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-ServicesBounded' }, $true)
$t13StopCalls = @($t13StopFn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Stop-Service' }, $true))
$t13StopParams = @($t13StopCalls | ForEach-Object { $_.CommandElements } | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
Check 'T13 stop source: one Stop-Service call' $t13StopCalls.Count 1
Check 'T13 stop source: uses -NoWait' ($t13StopParams -contains 'NoWait') $true
Check 'T13 stop source: never -Force' ($t13StopParams -contains 'Force') $false

# Start-ServicesBounded: Start() then WaitForStatus with the time left; the final state decides.
& {
    $t13Events = New-Object System.Collections.ArrayList
    function New-T13FakeService([string] $Name, [string] $Status, [string] $Behaviour) {
        $o = [pscustomobject]@{ Name = $Name; Status = $Status; Behaviour = $Behaviour; Events = $t13Events }
        $o | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
        $o | Add-Member -MemberType ScriptMethod -Name Start -Value {
            [void]$this.Events.Add("start:$($this.Name)")
            if ($this.Behaviour -eq 'fails') { throw 'The service did not respond to the start or control request in a timely fashion.' }
            if ($this.Behaviour -eq 'slow') { $this.Status = 'Running'; throw 'Time out has expired.' }
            $this.Status = 'Running'
        }
        $o | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
            param($Desired, $Timeout)
            [void]$this.Events.Add("wait:$($this.Name):${Desired}:$([math]::Round($Timeout.TotalSeconds))")
            if ("$($this.Status)" -ne "$Desired") { throw 'Time out has expired and the operation has not been completed.' }
        }
        return $o
    }
    $t13Fakes = @{
        VeeamBackupSvc  = (New-T13FakeService 'VeeamBackupSvc' 'Stopped' 'ok')
        VeeamAlreadySvc = (New-T13FakeService 'VeeamAlreadySvc' 'Running' 'ok')
        VeeamBrokenSvc  = (New-T13FakeService 'VeeamBrokenSvc' 'Stopped' 'fails')
        VeeamSlowSvc    = (New-T13FakeService 'VeeamSlowSvc' 'Stopped' 'slow')
    }
    function Get-Service {
        [CmdletBinding()] param([Parameter(Position = 0)][string[]] $Name)
        if ($t13Fakes.ContainsKey($Name[0])) { $t13Fakes[$Name[0]] }
    }
    $t13R = Start-ServicesBounded -Names @('VeeamBackupSvc', 'VeeamAlreadySvc', 'VeeamBrokenSvc', 'VeeamSlowSvc', 'VeeamGoneSvc') -TimeoutSec 30
    Check 'T13 start: not Ok when one fails' $t13R.Ok $false
    Check 'T13 start: started includes running and slow' (@($t13R.Started) -join ',') 'VeeamBackupSvc,VeeamAlreadySvc,VeeamSlowSvc'
    Check 'T13 start: broken and missing not started' (@($t13R.NotStarted) -join ',') 'VeeamBrokenSvc,VeeamGoneSvc'
    Check 'T13 start: Start() called in order, never for a running one' (@($t13Events | Where-Object { $_ -like 'start:*' }) -join ',') 'start:VeeamBackupSvc,start:VeeamBrokenSvc,start:VeeamSlowSvc'
    $t13Waits = @($t13Events | Where-Object { $_ -like 'wait:*' })
    Check 'T13 start: waits for Running' (@($t13Waits | Where-Object { $_ -notlike 'wait:*:Running:*' }).Count) 0
    Check 'T13 start: first wait gets the whole budget' $t13Waits[0] 'wait:VeeamBackupSvc:Running:30'
    Check 'T13 start: no wait is longer than the budget' (@($t13Waits | Where-Object { [int]($_ -replace '^.*:', '') -gt 30 }).Count) 0
}
& {
    $t13Fake = [pscustomobject]@{ Name = 'VeeamOkSvc'; Status = 'Stopped' }
    $t13Fake | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
    $t13Fake | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.Status = 'Running' }
    $t13Fake | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($Desired, $Timeout) if ("$($this.Status)" -ne "$Desired") { throw 'timeout' } }
    function Get-Service { [CmdletBinding()] param([Parameter(Position = 0)][string[]] $Name) if ($Name[0] -eq 'VeeamOkSvc') { $t13Fake } }
    $t13R = Start-ServicesBounded -Names @('VeeamOkSvc') -TimeoutSec 10
    Check 'T13 start: all started is Ok' "$($t13R.Ok)/$(@($t13R.Started) -join ',')/$(@($t13R.NotStarted).Count)" 'True/VeeamOkSvc/0'
    $t13R = Start-ServicesBounded -Names @() -TimeoutSec 10
    Check 'T13 start: empty list is Ok' "$($t13R.Ok)/$(@($t13R.Started).Count)" 'True/0'
}

# Test-ServiceStaysRunning: polls every 5 s; any non-Running read is a failure.
& {
    $t13Reads = @{ N = 0 }
    $t13Sleeps = New-Object System.Collections.ArrayList
    function Get-Service {
        [CmdletBinding()] param([Parameter(Position = 0)][string[]] $Name)
        $t13Reads.N++
        if ($t13Reads.N -ge 3) { [pscustomobject]@{ Name = $Name[0]; Status = 'Stopped' } }
        else { [pscustomobject]@{ Name = $Name[0]; Status = 'Running' } }
    }
    function Start-Sleep { [CmdletBinding()] param([int] $Seconds, [int] $Milliseconds) [void]$t13Sleeps.Add($Milliseconds) }
    Check 'T13 settle: a stop during the window fails' (Test-ServiceStaysRunning -Name 'VeeamBackupSvc' -Seconds 300) $false
    Check 'T13 settle: stopped at the third read' $t13Reads.N 3
    Check 'T13 settle: polls every 5 s' $t13Sleeps[0] 5000
}
& {
    $t13Sleeps = New-Object System.Collections.ArrayList
    function Get-Service { [CmdletBinding()] param([Parameter(Position = 0)][string[]] $Name) [pscustomobject]@{ Name = $Name[0]; Status = 'Running' } }
    function Start-Sleep { [CmdletBinding()] param([int] $Seconds, [int] $Milliseconds) [void]$t13Sleeps.Add($Milliseconds); Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 300 }
    Check 'T13 settle: running for the whole window passes' (Test-ServiceStaysRunning -Name 'VeeamBackupSvc' -Seconds 1) $true
    Check 'T13 settle: never sleeps past the window' (@($t13Sleeps | Where-Object { $_ -gt 1000 }).Count) 0
    Check 'T13 settle: zero seconds is one read' (Test-ServiceStaysRunning -Name 'VeeamBackupSvc' -Seconds 0) $true
}
Check 'T13 settle: a missing service fails' (Test-ServiceStaysRunning -Name "NoSuchService-VbrStd-$PID" -Seconds 0) $false
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: every earlier check still prints `PASS`. The Task 13 section prints 45 `FAIL  UNHANDLED` lines, the first being `  FAIL  UNHANDLED  The term 'Get-BusyVeeamWork' is not recognized as the name of a cmdlet, function, script file, or operable program.` followed by the usual spelling hint (later ones say that a variable such as `$t13Busy` has not been set), plus `  FAIL  T13 snapshot: runs read-only on this machine  expected 'True' got 'False'`. Only `T13 snapshot: a failed enumeration throws` passes, because calling a missing function throws too. The last line is `RESULT: <p> passed, 46 failed`, where `<p>` is the total from before this task plus 1. Exit code 1.

- [ ] **Step 3: Implement**

Insert this block in `Invoke-VbrStandardise.ps1` directly above the line `#endregion Services`:

```powershell
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: every check whose name starts with `T13` prints `PASS`, and the last line is `RESULT: <n> passed, 0 failed`, where `<n>` is the total from before this task plus 67 (`RESULT: 1063 passed, 0 failed` on an elevated prompt on English Windows without PostgreSQL or VBR). Exit code 0.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add the idle gate and bounded Veeam service stop and start" -m "Path B must see busy Veeam work, find the services to stop and any outside dependent, and stop and start them within ServiceStopTimeoutSec with Stop-Service -NoWait (never -Force) and no startup-type change (spec 7.11, 7.12). The start order is the updater's dependency sort, with alphabetical waves." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Registry switch, backup and restore

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region Registry)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Write-Log`, `Format-ShortText`, `Invoke-Native`, `Get-CfgValue`, `Write-AtomicJson` (Task 1)
- Produces: `Get-RegistryValueSnapshot`, `ConvertTo-RegExePath`, `Save-RegistryBackup`, `Get-RegistryTargets`, `Set-RegistryTargets`, `Restore-RegistrySnapshot`

Spec: 7.6 Path B steps 4 and 8, rollback step 3; 9. The backup pattern (reg.exe export, then refuse unless the file exists and is not empty) is adapted from the updater's `Remove-StaleVeeamRegistryRecord`.

Notes for this task:
- `Get-RegistryValueSnapshot` returns a plain `@{}` hashtable (case-insensitive keys) because `Save-RegistryBackup` and `Restore-RegistrySnapshot` take `[hashtable]`; an `[ordered]` dictionary would not bind. Each entry is `[pscustomobject]@{ Exists; Kind; Data }`; `Kind` is the `RegistryValueKind` name (for example `String` or `DWord`), `''` when absent.
- `registry-before.json` holds `KeyPath`, `ExportKey`, `RegExport`, `Time` and `Values.<name> = { State = 'present'|'absent'; Kind; Data }`. It and `vbr-key.reg` are the only places the `SqlSecuredPassword` data may be copied to (spec 9); `Write-Log` never receives it, which a test checks.
- `Save-RegistryBackup` accepts `-ExportKeyPath` in PowerShell form (`HKLM:\SOFTWARE\X`, converted with `ConvertTo-RegExePath`) or already in reg.exe form (`HKLM\SOFTWARE\X`). Task 17 passes `ConvertTo-RegExePath -KeyPath $Ctx.Db.KeyPath`, which is the `DatabaseConfigurations\PostgreSql` key itself, not the VBR root key: a fallback `reg.exe import` in the rollback then touches only the database settings.
- `reg.exe import` only adds and overwrites values, so `Restore-RegistrySnapshot` deletes the values that were absent in the snapshot once before the import and again after it.
- The tests use a throwaway key `HKCU:\Software\VbrStdTest-<PID>` whose subkey names have spaces, like the real VBR key, so the quoting of reg.exe arguments in `Invoke-Native` is exercised too. The key is removed in `finally`. Mock state variables have the `t14` prefix (see the Task 13 note on mock scoping).

- [ ] **Step 1: Write the failing tests**

Insert this block in `Test-VbrStandardise.ps1` directly above the line `# ===================== RESULT =====================` (below the Task 13 block). It touches only `HKCU:\Software\VbrStdTest-<PID>` and folders from `New-TestFolder`, and runs the real `reg.exe export` and `reg.exe import` on that HKCU key only.

```powershell
# --- Task 14: Registry switch, backup and restore ---

Check 'T14 reg path: HKLM' (ConvertTo-RegExePath -KeyPath 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication') 'HKLM\SOFTWARE\Veeam\Veeam Backup and Replication'
Check 'T14 reg path: HKCU, trailing slash' (ConvertTo-RegExePath -KeyPath 'HKCU:\Software\X\') 'HKCU\Software\X'
Check 'T14 reg path: lower-case hive' (ConvertTo-RegExePath -KeyPath 'hklm:\software\x') 'HKLM\software\x'
Check 'T14 reg path: provider path' (ConvertTo-RegExePath -KeyPath 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\X') 'HKLM\SOFTWARE\X'
Throws 'T14 reg path: file path refused' { ConvertTo-RegExePath -KeyPath 'C:\Windows' }
Throws 'T14 reg path: other hive refused' { ConvertTo-RegExePath -KeyPath 'HKCR:\x' }

$t14Db = [pscustomobject]@{ HostName = 'VBR01'; Port = 5432; DatabaseName = 'VeeamBackup'; UserName = 'postgres'; PasswordSet = $true; WindowsAuthRole = $null }
$t14T = Get-RegistryTargets -DbConfig $t14Db -Addresses @('127.0.0.1', '::1')
Check 'T14 targets: ordered dictionary' ($t14T -is [System.Collections.Specialized.OrderedDictionary]) $true
Check 'T14 targets: names in order' (@($t14T.Keys) -join ',') 'SqlUserName,SqlSecuredPassword,PostgresUserForWindowsAuth,SqlHostName'
Check 'T14 targets: values' (@($t14T.Values | ForEach-Object { "<$_>" }) -join '') '<><><postgres><127.0.0.1>'
Check 'T14 targets: only ::1 listens' (Get-RegistryTargets -DbConfig $t14Db -Addresses @('::1'))['SqlHostName'] '::1'
Check 'T14 targets: 127.0.0.1 preferred' (Get-RegistryTargets -DbConfig $t14Db -Addresses @('::1', '127.0.0.1'))['SqlHostName'] '127.0.0.1'
$t14Win = [pscustomobject]@{ HostName = 'localhost'; WindowsAuthRole = 'postgres' }
Check 'T14 targets: loopback host and postgres role kept' (@((Get-RegistryTargets -DbConfig $t14Win -Addresses @('127.0.0.1')).Keys) -join ',') 'SqlUserName,SqlSecuredPassword'
$t14Case = @{ HostName = '::1'; WindowsAuthRole = 'Postgres' }
Check 'T14 targets: role compared case-sensitively, ::1 kept' (@((Get-RegistryTargets -DbConfig $t14Case -Addresses @('::1')).Keys) -join ',') 'SqlUserName,SqlSecuredPassword,PostgresUserForWindowsAuth'

# A throwaway copy of the spec 9 native-auth key, with PostgresUserForWindowsAuth absent
# and a non-loopback SqlHostName so that every switch rule changes something. The key
# names have spaces, like the real VBR key, so reg.exe quoting is exercised.
$t14Root = "HKCU:\Software\VbrStdTest-$PID"
$t14Vbr = "$t14Root\Veeam Backup and Replication"
$t14Key = "$t14Vbr\DatabaseConfigurations\PostgreSql"
$t14Names = @('SqlUserName', 'SqlSecuredPassword', 'PostgresUserForWindowsAuth', 'SqlHostName')
$t14Lock = '<CLockInfo><Computer>VBR01</Computer><UserName>SYSTEM</UserName><Time>2026-10-01T10:00:00</Time></CLockInfo>'
$t14Show = { param($Entry) "$($Entry.Exists)|$($Entry.Kind)|$($Entry.Data)" }
try {
    if (Test-Path -LiteralPath $t14Root) { Remove-Item -LiteralPath $t14Root -Recurse -Force }
    $null = New-Item -Path $t14Key -Force
    $null = New-ItemProperty -LiteralPath $t14Key -Name 'SqlDatabaseName' -Value 'VeeamBackup' -PropertyType String
    $null = New-ItemProperty -LiteralPath $t14Key -Name 'SqlHostName' -Value 'VBR01' -PropertyType String
    $null = New-ItemProperty -LiteralPath $t14Key -Name 'SqlHostPort' -Value 5432 -PropertyType DWord
    $null = New-ItemProperty -LiteralPath $t14Key -Name 'SqlUserName' -Value 'postgres' -PropertyType String
    $null = New-ItemProperty -LiteralPath $t14Key -Name 'SqlSecuredPassword' -Value 'AQAAANCM-fake' -PropertyType String
    $null = New-ItemProperty -LiteralPath $t14Key -Name 'SqlLockInfo' -Value $t14Lock -PropertyType String
    $t14LogStart = $script:LogLines.Count

    $t14Snap = Get-RegistryValueSnapshot -KeyPath $t14Key -Names $t14Names
    Check 'T14 snapshot: is a hashtable' ($t14Snap -is [hashtable]) $true
    Check 'T14 snapshot: SqlUserName' (& $t14Show $t14Snap['SqlUserName']) 'True|String|postgres'
    Check 'T14 snapshot: SqlSecuredPassword' (& $t14Show $t14Snap['SqlSecuredPassword']) 'True|String|AQAAANCM-fake'
    Check 'T14 snapshot: PostgresUserForWindowsAuth absent' (& $t14Show $t14Snap['PostgresUserForWindowsAuth']) 'False||'
    Check 'T14 snapshot: SqlHostName' (& $t14Show $t14Snap['SqlHostName']) 'True|String|VBR01'
    Check 'T14 snapshot: DWord kind' (& $t14Show (Get-RegistryValueSnapshot -KeyPath $t14Key -Names @('SqlHostPort'))['SqlHostPort']) 'True|DWord|5432'
    Check 'T14 snapshot: missing key reads as absent' (& $t14Show (Get-RegistryValueSnapshot -KeyPath "$t14Root\No Such Key" -Names @('A'))['A']) 'False||'

    $t14Run = New-TestFolder 'reg'
    $t14Backup = Save-RegistryBackup -KeyPath $t14Key -ExportKeyPath $t14Vbr -RunDir $t14Run -Snapshot $t14Snap
    Check 'T14 backup: json path' $t14Backup.JsonPath (Join-Path $t14Run 'registry-before.json')
    Check 'T14 backup: reg path' $t14Backup.RegPath (Join-Path $t14Run 'vbr-key.reg')
    $t14Doc = [IO.File]::ReadAllText($t14Backup.JsonPath) | ConvertFrom-Json
    Check 'T14 backup: json keeps the old password data' $t14Doc.Values.SqlSecuredPassword.Data 'AQAAANCM-fake'
    Check 'T14 backup: json present value' "$($t14Doc.Values.SqlUserName.State)|$($t14Doc.Values.SqlUserName.Kind)|$($t14Doc.Values.SqlUserName.Data)" 'present|String|postgres'
    Check 'T14 backup: json absent value' $t14Doc.Values.PostgresUserForWindowsAuth.State 'absent'
    Check 'T14 backup: json export key in reg.exe form' $t14Doc.ExportKey "HKCU\Software\VbrStdTest-$PID\Veeam Backup and Replication"
    Check 'T14 backup: reg export not empty' ((Get-Item -LiteralPath $t14Backup.RegPath).Length -gt 0) $true
    $t14RegText = [IO.File]::ReadAllText($t14Backup.RegPath)
    Check 'T14 backup: reg export holds the key' ($t14RegText.Contains("VbrStdTest-$PID\Veeam Backup and Replication\DatabaseConfigurations\PostgreSql")) $true
    Check 'T14 backup: reg export holds the values' ($t14RegText.Contains('"SqlSecuredPassword"="AQAAANCM-fake"')) $true
    $t14Run2 = New-TestFolder 'reg'
    $t14Backup2 = Save-RegistryBackup -KeyPath $t14Key -ExportKeyPath (ConvertTo-RegExePath -KeyPath $t14Vbr) -RunDir $t14Run2 -Snapshot $t14Snap
    Check 'T14 backup: reg.exe form export key accepted' (Test-Path -LiteralPath $t14Backup2.RegPath) $true
    $t14Run3 = New-TestFolder 'reg'
    Throws 'T14 backup: throws when the export fails' { Save-RegistryBackup -KeyPath $t14Key -ExportKeyPath "$t14Root\No Such Key" -RunDir $t14Run3 -Snapshot $t14Snap }
    Check 'T14 backup: no empty export left behind' (Test-Path -LiteralPath (Join-Path $t14Run3 'vbr-key.reg')) $false
    Throws 'T14 backup: throws when the run folder is missing' { Save-RegistryBackup -KeyPath $t14Key -ExportKeyPath $t14Vbr -RunDir (Join-Path $t14Run3 'missing') -Snapshot $t14Snap }

    Set-RegistryTargets -KeyPath $t14Key -Targets (Get-RegistryTargets -DbConfig $t14Db -Addresses @('127.0.0.1'))
    $t14After = Get-RegistryValueSnapshot -KeyPath $t14Key -Names ($t14Names + @('SqlHostPort', 'SqlLockInfo', 'SqlDatabaseName'))
    Check 'T14 switch: SqlUserName empty String' (& $t14Show $t14After['SqlUserName']) 'True|String|'
    Check 'T14 switch: SqlSecuredPassword empty String' (& $t14Show $t14After['SqlSecuredPassword']) 'True|String|'
    Check 'T14 switch: PostgresUserForWindowsAuth created' (& $t14Show $t14After['PostgresUserForWindowsAuth']) 'True|String|postgres'
    Check 'T14 switch: SqlHostName loopback' (& $t14Show $t14After['SqlHostName']) 'True|String|127.0.0.1'
    Check 'T14 switch: SqlHostPort untouched' (& $t14Show $t14After['SqlHostPort']) 'True|DWord|5432'
    Check 'T14 switch: SqlLockInfo untouched' (& $t14Show $t14After['SqlLockInfo']) "True|String|$t14Lock"
    Check 'T14 switch: SqlDatabaseName untouched' (& $t14Show $t14After['SqlDatabaseName']) 'True|String|VeeamBackup'
    & {
        function New-ItemProperty { [CmdletBinding()] param([string] $LiteralPath, [string] $Name, $Value, [string] $PropertyType, [switch] $Force) }
        Throws 'T14 switch: throws when a value does not read back' { Set-RegistryTargets -KeyPath $t14Key -Targets ([ordered]@{ SqlHostName = '::1' }) }
    }
    Throws 'T14 switch: throws when the key is missing' { Set-RegistryTargets -KeyPath "$t14Root\No Such Key" -Targets ([ordered]@{ SqlUserName = '' }) }

    $t14LogMark = $script:LogLines.Count
    Check 'T14 restore: direct restore succeeds' (Restore-RegistrySnapshot -KeyPath $t14Key -Snapshot $t14Snap -RegExportPath $t14Backup.RegPath) $true
    $t14Back = Get-RegistryValueSnapshot -KeyPath $t14Key -Names $t14Names
    foreach ($t14Name in $t14Names) {
        Check "T14 restore: $t14Name round-trips" (& $t14Show $t14Back[$t14Name]) (& $t14Show $t14Snap[$t14Name])
    }
    Check 'T14 restore: value absent before is deleted' ($t14Back['PostgresUserForWindowsAuth'].Exists) $false
    Check 'T14 restore: no reg import needed' (@($script:LogLines | Select-Object -Skip $t14LogMark | Where-Object { $_ -like '*Imported the reg.exe export*' }).Count) 0

    # Fallback: the direct writes and the first delete fail, so the export is imported
    # and the value that was absent is deleted after the import.
    Set-RegistryTargets -KeyPath $t14Key -Targets (Get-RegistryTargets -DbConfig $t14Db -Addresses @('127.0.0.1'))
    $t14LogMark = $script:LogLines.Count
    & {
        $t14Removals = @{ N = 0 }
        function New-ItemProperty { [CmdletBinding()] param([string] $LiteralPath, [string] $Name, $Value, [string] $PropertyType, [switch] $Force) }
        function Remove-ItemProperty {
            [CmdletBinding()] param([string] $LiteralPath, [string] $Name)
            $t14Removals.N++
            if ($t14Removals.N -gt 1) { Microsoft.PowerShell.Management\Remove-ItemProperty -LiteralPath $LiteralPath -Name $Name -ErrorAction Stop }
        }
        Check 'T14 fallback: restore succeeds through reg import' (Restore-RegistrySnapshot -KeyPath $t14Key -Snapshot $t14Snap -RegExportPath $t14Backup.RegPath) $true
        Check 'T14 fallback: absent value deleted after the import' $t14Removals.N 2
    }
    $t14Back = Get-RegistryValueSnapshot -KeyPath $t14Key -Names $t14Names
    foreach ($t14Name in $t14Names) {
        Check "T14 fallback: $t14Name round-trips" (& $t14Show $t14Back[$t14Name]) (& $t14Show $t14Snap[$t14Name])
    }
    Check 'T14 fallback: import logged' (@($script:LogLines | Select-Object -Skip $t14LogMark | Where-Object { $_ -like '*Imported the reg.exe export*' }).Count) 1

    # Without a usable export the restore reports failure instead of throwing.
    Set-RegistryTargets -KeyPath $t14Key -Targets (Get-RegistryTargets -DbConfig $t14Db -Addresses @('127.0.0.1'))
    & {
        function New-ItemProperty { [CmdletBinding()] param([string] $LiteralPath, [string] $Name, $Value, [string] $PropertyType, [switch] $Force) }
        Check 'T14 fallback: no export path gives false' (Restore-RegistrySnapshot -KeyPath $t14Key -Snapshot $t14Snap) $false
        Check 'T14 fallback: missing export file gives false' (Restore-RegistrySnapshot -KeyPath $t14Key -Snapshot $t14Snap -RegExportPath (Join-Path $t14Run3 'none.reg')) $false
    }
    Check 'T14 restore: real restore after the failed ones' (Restore-RegistrySnapshot -KeyPath $t14Key -Snapshot $t14Snap) $true
    Check 'T14 log: never holds the password data' (@($script:LogLines | Select-Object -Skip $t14LogStart | Where-Object { $_ -like '*AQAAANCM*' }).Count) 0
} finally {
    if (Test-Path -LiteralPath $t14Root) { Remove-Item -LiteralPath $t14Root -Recurse -Force }
}
Check 'T14 cleanup: throwaway key removed' (Test-Path -LiteralPath $t14Root) $false
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: every earlier check, the `T13` checks included, still prints `PASS`. The Task 14 section prints 13 `FAIL  UNHANDLED` lines, the first being `  FAIL  UNHANDLED  The term 'ConvertTo-RegExePath' is not recognized as the name of a cmdlet, function, script file, or operable program.` followed by the usual spelling hint; the last one comes from the `try` block, which stops at `Get-RegistryValueSnapshot`. Only `T14 reg path: file path refused` and `T14 reg path: other hive refused` (calling a missing function throws too) and `T14 cleanup: throwaway key removed` pass. The last line is `RESULT: <p> passed, 13 failed`, where `<p>` is the total from before this task plus 3. Exit code 1. The `finally` block has removed the throwaway key: `Test-Path HKCU:\Software\VbrStdTest-*` is `False`.

- [ ] **Step 3: Implement**

Insert this block in `Invoke-VbrStandardise.ps1` directly above the line `#endregion Registry`:

```powershell
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: every check whose name starts with `T13` or `T14` prints `PASS`, and the last line is `RESULT: <n> passed, 0 failed`, where `<n>` is the total from before this task plus 61 (`RESULT: 1124 passed, 0 failed` on an elevated prompt on English Windows without PostgreSQL or VBR). Exit code 0. Afterwards `Test-Path HKCU:\Software\VbrStdTest-*` is `False`.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add the registry switch with a verified backup and restore" -m "Path B saves registry-before.json and a reg.exe export before it writes the Windows-auth values and reads every value back; the rollback writes the old values, deletes values that were absent, and falls back to importing the export, comparing every value each time (spec 7.6, 9)." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: VBR connect check

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region ConnectCheck)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Write-Log -Message -Level`, `Format-ShortText -Text -MaxLength`, `Get-CfgValue -Object -Name -Default` (Task 1); `Get-PgLiveState -Psql -Port -Address -Database` (Task 11).
- Produces: `Get-FileLength`, `Read-LogTail`, `Find-AuthErrors`, `Test-VbrConnectEvidence`, `Wait-VbrDbConnected`.

Notes for the engineer:
- Spec 7.13 (Path B step 10), also used by the rollback settle check (spec 7.6 rollback step 5) through `Get-FileLength`, `Read-LogTail` and `Find-AuthErrors`.
- The caller takes `LogOffset = Get-FileLength` of `C:\ProgramData\Veeam\Backup\Svc.VeeamBackup.log` and `SinceUtc = [DateTime]::UtcNow` just before it starts the services. Only lines written after that offset count. If Veeam rolls the log over and the new file is shorter than the offset, the whole new file counts.
- Files are opened with `FileShare.ReadWrite` and `Delete`, so the running Backup Service can keep writing and rolling its log while the script reads it. The length comes from the open stream, not from the directory entry, which NTFS can update late for a file that another process holds open.
- `28000` and `28P01` count only as a SQLSTATE followed by a colon (`28000:`), the form Npgsql and psql print. A number such as `Received 28000 bytes` is not an authentication error.

- [ ] **Step 1: Write the failing tests**

Insert this block in `Test-VbrStandardise.ps1` directly above the line `# ===================== RESULT =====================`.

```powershell
# --- Task 15: VBR connect check ---
try {
    & {
        $dir = New-TestFolder 'logtail'
        $missing = Join-Path $dir 'missing.log'
        Check 'file length: missing file is 0'                (Get-FileLength -Path $missing) 0
        Check 'file length: returns a long'                   (Get-FileLength -Path $missing).GetType().Name 'Int64'
        $five = Join-Path $dir 'five.txt'
        [IO.File]::WriteAllBytes($five, [byte[]](65, 66, 67, 68, 69))
        Check 'file length: five bytes'                       (Get-FileLength -Path $five) 5

        $log = Join-Path $dir 'Svc.VeeamBackup.log'
        [IO.File]::WriteAllText($log, "[12.10.2026 10:00:00] <01> Info  old line one`r`n[12.10.2026 10:00:01] <01> Error no match in usermap `"veeam`" (old)`r`n", [Text.Encoding]::ASCII)
        $offset = Get-FileLength -Path $log
        [IO.File]::AppendAllText($log, "[12.10.2026 10:05:00] <01> Info  new line one`r`n[12.10.2026 10:05:01] <01> Info  new line two`r`n", [Text.Encoding]::ASCII)
        $tail = @(Read-LogTail -Path $log -FromOffset $offset)
        Check 'log tail: only lines after the offset'         $tail.Count 2
        Check 'log tail: first new line'                      $tail[0] '[12.10.2026 10:05:00] <01> Info  new line one'
        Check 'log tail: second new line'                     $tail[1] '[12.10.2026 10:05:01] <01> Info  new line two'
        Check 'log tail: nothing new at the end'              @(Read-LogTail -Path $log -FromOffset (Get-FileLength -Path $log)).Count 0
        Check 'log tail: offset 0 reads the whole file'       @(Read-LogTail -Path $log -FromOffset 0).Count 4

        $short = Join-Path $dir 'rolled.log'
        [IO.File]::WriteAllText($short, "a`r`nb`n", [Text.Encoding]::ASCII)
        $rolled = @(Read-LogTail -Path $short -FromOffset 100000)
        Check 'log tail: shorter file is read from the start' ($rolled -join ',') 'a,b'
        Check 'log tail: missing file gives no lines'         @(Read-LogTail -Path $missing -FromOffset 0).Count 0

        $held = Join-Path $dir 'held.log'
        $writer = New-Object -TypeName System.IO.FileStream -ArgumentList @($held, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $bytes = [Text.Encoding]::ASCII.GetBytes("held open line`r`n")
            $writer.Write($bytes, 0, $bytes.Length)
            $writer.Flush()
            Check 'log tail: length of a file held open for writing' (Get-FileLength -Path $held) 16
            Check 'log tail: reads a file held open for writing'     ((@(Read-LogTail -Path $held -FromOffset 0)) -join ',') 'held open line'
        } finally {
            $writer.Dispose()
        }
    }
} catch {
    Check 'Task 15: log tail tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        $lines = @(
            '[12.10.2026 10:05:00] <01> Info  Starting Veeam Backup Service',
            '[12.10.2026 10:05:01] <07> Error Npgsql.PostgresException (0x80004005): 28000: no pg_hba.conf entry for host "127.0.0.1", user "postgres", database "VeeamBackup", no encryption',
            '[12.10.2026 10:05:02] <07> Error 28P01: Passwort-Authentifizierung fehlgeschlagen',
            '[12.10.2026 10:05:03] <07> Error FATAL: SSPI authentication failed for user "postgres"',
            '[12.10.2026 10:05:04] <01> Info  Received 28000 bytes',
            '[12.10.2026 10:05:05] <01> Info  SSPI package negotiated',
            '[12.10.2026 10:05:06] <07> Error no match in usermap "veeam" for user "postgres" authenticated as "Administrator@VBR01"',
            '[12.10.2026 10:05:07] <07> Error password authentication failed for user "postgres"'
        )
        $found = @(Find-AuthErrors -Lines $lines)
        Check 'auth errors: five matching lines'              $found.Count 5
        Check 'auth errors: SQLSTATE 28000 line first'        $found[0] $lines[1]
        Check 'auth errors: localised 28P01 line'             ($found -contains $lines[2]) 'True'
        Check 'auth errors: byte count is not 28000'          ($found -contains $lines[4]) 'False'
        Check 'auth errors: bare SSPI is not an error'        ($found -contains $lines[5]) 'False'
        Check 'auth errors: no lines'                         @(Find-AuthErrors -Lines @()).Count 0
    }
} catch {
    Check 'Task 15: Find-AuthErrors tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        $since = New-Object DateTime 2026, 10, 12, 10, 0, 0, ([DateTimeKind]::Utc)
        $be = { param($Db, $User, $Addr, [int] $Minutes) [pscustomobject]@{ Pid = 9; UseName = $User; DatName = $Db; ClientAddr = $Addr; BackendStartUtc = $since.AddMinutes($Minutes) } }
        $evidence = { param($Backends, $Since) Test-VbrConnectEvidence -Backends $Backends -SinceUtc $Since -Database 'VeeamBackup' }
        Check 'connect evidence: new loopback postgres session'      (& $evidence @(& $be 'VeeamBackup' 'postgres' '127.0.0.1' 5) $since) 'True'
        Check 'connect evidence: session older than T'               (& $evidence @(& $be 'VeeamBackup' 'postgres' '127.0.0.1' -5) $since) 'False'
        Check 'connect evidence: session started exactly at T'       (& $evidence @(& $be 'VeeamBackup' 'postgres' '127.0.0.1' 0) $since) 'False'
        Check 'connect evidence: database name case-insensitive, ::1' (& $evidence @(& $be 'veeambackup' 'postgres' '::1' 1) $since) 'True'
        Check 'connect evidence: other role'                         (& $evidence @(& $be 'VeeamBackup' 'pg_native_admin' '127.0.0.1' 5) $since) 'False'
        Check 'connect evidence: LAN address'                        (& $evidence @(& $be 'VeeamBackup' 'postgres' '192.168.1.10' 5) $since) 'False'
        Check 'connect evidence: other database'                     (& $evidence @(& $be 'postgres' 'postgres' '127.0.0.1' 5) $since) 'False'
        Check 'connect evidence: no sessions'                        (& $evidence @() $since) 'False'
        Check 'connect evidence: one good session among others'      (& $evidence @((& $be 'postgres' 'postgres' '127.0.0.1' 5), (& $be 'VeeamBackup' 'postgres' '127.0.0.1' -1), (& $be 'VeeamBackup' 'postgres' '::1' 2)) $since) 'True'
        Check 'connect evidence: local-time T is converted to UTC'   (& $evidence @(& $be 'VeeamBackup' 'postgres' '127.0.0.1' 5) $since.ToLocalTime()) 'True'
        Check 'connect evidence: local-time T, older session'        (& $evidence @(& $be 'VeeamBackup' 'postgres' '127.0.0.1' -5) $since.ToLocalTime()) 'False'
    }
} catch {
    Check 'Task 15: Test-VbrConnectEvidence tests ran to the end' $_.Exception.Message ''
}

try {
    & {
        $dir = New-TestFolder 'connect'
        $log = Join-Path $dir 'Svc.VeeamBackup.log'
        [IO.File]::WriteAllText($log, "[old] <07> Error no match in usermap `"veeam`" written before the services started`r`n", [Text.Encoding]::ASCII)
        $offset = Get-FileLength -Path $log
        $since = New-Object DateTime 2026, 10, 12, 10, 0, 0, ([DateTimeKind]::Utc)
        $calls = New-Object System.Collections.ArrayList
        $plan = @{ Service = 'Running'; GoodFromPoll = 2; LiveOk = $true }
        function Get-Service {
            [CmdletBinding()] param([string] $Name)
            [void]$calls.Add("svc:$Name")
            [pscustomobject]@{ Name = $Name; Status = $plan.Service }
        }
        function Start-Sleep {
            [CmdletBinding()] param([int] $Seconds)
            [void]$calls.Add("sleep:$Seconds")
        }
        function Get-PgLiveState {
            param([string] $Psql, [int] $Port, [string] $Address, [string] $Database)
            [void]$calls.Add("live:$Address|$Port|$Database")
            $poll = @($calls | Where-Object { "$_" -like 'live:*' }).Count
            $start = $since.AddSeconds(-30)
            if ($poll -ge $plan.GoodFromPoll) { $start = $since.AddSeconds(30) }
            [pscustomobject]@{
                Ok          = $plan.LiveOk
                PasswordSet = $true
                Backends    = @([pscustomobject]@{ Pid = 7; UseName = 'postgres'; DatName = 'VeeamBackup'; ClientAddr = '127.0.0.1'; BackendStartUtc = $start })
            }
        }
        $wait = {
            param([int] $TimeoutSec, [long] $LogOffset, [string] $ServiceName = 'VeeamBackupSvc')
            Wait-VbrDbConnected -Psql 'psql.exe' -Port 5432 -Address '127.0.0.1' -Database 'VeeamBackup' -SinceUtc $since -TimeoutSec $TimeoutSec -LogPath $log -LogOffset $LogOffset -PollSec 7 -ServiceName $ServiceName
        }

        $r = & $wait 600 $offset
        Check 'connect wait: succeeds once a new session appears'  $r.Ok 'True'
        Check 'connect wait: polled pg_stat_activity twice'        (@($calls | Where-Object { "$_" -like 'live:*' }).Count) 2
        Check 'connect wait: queried the given address and database' ($calls -contains 'live:127.0.0.1|5432|VeeamBackup') 'True'
        Check 'connect wait: slept once with the poll interval'    (@($calls | Where-Object { "$_" -like 'sleep:*' }) -join ',') 'sleep:7'
        Check 'connect wait: checked VeeamBackupSvc'               ($calls -contains 'svc:VeeamBackupSvc') 'True'

        $calls.Clear()
        [IO.File]::AppendAllText($log, "[new] <07> Error Npgsql.PostgresException (0x80004005): 28000: no pg_hba.conf entry for host `"127.0.0.1`"`r`n", [Text.Encoding]::ASCII)
        $plan.GoodFromPoll = 1
        $r = & $wait 600 $offset
        Check 'connect wait: auth error in the log fails'          $r.Ok 'False'
        Check 'connect wait: auth error line in Detail'            ($r.Detail -match 'no pg_hba\.conf entry') 'True'
        Check 'connect wait: auth error fails without waiting'     (@($calls | Where-Object { "$_" -like 'sleep:*' }).Count) 0

        $offset = Get-FileLength -Path $log
        $calls.Clear()
        $plan.Service = 'Stopped'
        $plan.GoodFromPoll = 99
        $r = & $wait 0 $offset
        Check 'connect wait: times out'                            $r.Ok 'False'
        Check 'connect wait: timeout names the stopped service'    ($r.Detail -match 'VeeamBackupSvc is Stopped') 'True'
        Check 'connect wait: timeout names the missing session'    ($r.Detail -match 'no new') 'True'

        $calls.Clear()
        $plan.Service = 'Running'
        $plan.LiveOk = $false
        $r = & $wait 0 $offset
        Check 'connect wait: failed SSPI query is not success'     $r.Ok 'False'
        Check 'connect wait: failed SSPI query named in Detail'    ($r.Detail -match 'SSPI query') 'True'

        $calls.Clear()
        $plan.LiveOk = $true
        $plan.GoodFromPoll = 1
        $r = & $wait 0 $offset 'VeeamFakeSvc'
        Check 'connect wait: other service name is used'           ($calls -contains 'svc:VeeamFakeSvc') 'True'
        Check 'connect wait: success on the first poll'            $r.Ok 'True'
    }
} catch {
    Check 'Task 15: Wait-VbrDbConnected tests ran to the end' $_.Exception.Message ''
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: the earlier checks still PASS and four new lines FAIL, one per group, for example:
`  FAIL  Task 15: log tail tests ran to the end  expected '' got 'The term 'Get-FileLength' is not recognized as the name of a cmdlet, function, script file, or operable program. ...'`
The other three name `Find-AuthErrors`, `Test-VbrConnectEvidence` and `Get-FileLength` (the connect group reads the log length first). The last line is `RESULT: <earlier total> passed, 4 failed` and the exit code is 1.

- [ ] **Step 3: Implement**

Insert this block in `Invoke-VbrStandardise.ps1` directly above the line `#endregion ConnectCheck`.

```powershell
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
# for are ASCII. Empty lines are dropped.
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: <n> passed, 0 failed`, where n is the previous total plus 44 (the new Task 15 checks), and exit code 0. On an elevated prompt on English Windows without PostgreSQL or VBR that is `RESULT: 1168 passed, 0 failed`.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add the VBR connect check for Path B" -m "After the services start, wait until VeeamBackupSvc runs and pg_stat_activity shows a new VBR session as postgres from loopback, and fail at once on any authentication error that Svc.VeeamBackup.log records after the start (spec 7.13)." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: Path A flow

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region PathA)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Write-Log`, `Get-DefaultConfig` (tests) (Task 1); `New-RunReport` (tests), `Add-RunIssue` (Task 2); `New-RunFolder`, `Write-ChangeMarker`, `Remove-ChangeMarker` (Task 3); `ConvertTo-Latin1Bytes`, `Write-ConfFileAtomic`, `Backup-ConfFile`, `Restore-ConfFile` (Task 8); `Get-NonLoopbackHbaRules`, `New-PgHbaText` (Task 9); `New-PgIdentText` (Task 10); `Test-PgSspiLogin`, `Test-PgConfigHealth`, `Clear-PostgresPassword` (Task 11); harness `Check`, `Throws`, `New-TestFolder`, `$script:LogLines` (Task 1).
- Produces:
  - `Invoke-PathA -Ctx <hashtable>` → `{ ExitCode:int; Code:string; Detail:string; Action:string }`. Sets `$script:Stage` (`PATH_A_WRITING`, then `PATH_A_DONE`). `Code` is `''` on success; `Action` is `''` when the default RMM action for the exit code fits. Results: 0; 40 `PG_SSPI_TEST_FAILED` (files restored, SSPI works again, marker removed); 50 `ROLLBACK_FAILED` (restore did not bring SSPI back, marker stays); 5 `PG_PASSWORD_NOT_CLEARED`. An unexpected error is not caught: after the marker it reaches the trap with stage `PATH_A_WRITING`. Both new texts are rendered before the backup and the marker, so a `New-PgIdentText` throw (a name that is not ASCII, Task 10) reaches the trap with stage `UNTOUCHED` and nothing changed.
  - `Restore-PathAFiles -Ctx <hashtable>` → bool (restores `pg_ident.conf`, then `pg_hba.conf`, from `$Ctx.IdentBackupPath`/`$Ctx.HbaBackupPath` with `Restore-ConfFile`, then `Test-PgSspiLogin`; never throws).
  - Private helper (not in the shared contract): `Clear-PathFixedIssues -Ctx <hashtable> [-IncludePassword]` → nothing. Removes `DB_NATIVE_AUTH`, `DB_HOST_NOT_LOCAL`, `DB_WINDOWS_ROLE_NOT_POSTGRES`, `PG_HBA_NOT_STANDARD`, `PG_IDENT_NOT_STANDARD` (and with `-IncludePassword` also `PG_POSTGRES_PASSWORD_SET`) from `$script:Issues`, sets `$Ctx.State` and `$script:Report` `DbAuth=WINDOWS`, `PgHba=STANDARD`, `PgIdent=STANDARD`, and `PgPassword=NONE` when `$Ctx.PasswordCleared`. Task 17 uses it too.

- [ ] **Step 1: Write the failing tests**

Insert this block just above the line `# ===================== RESULT =====================` in `Test-VbrStandardise.ps1`. Every function Path A calls is mocked inside `& { }` child scopes, so nothing real is read or written. `New-T16Ctx` builds a fake `$Ctx` that Task 17 and Task 18 tests reuse.

```powershell
# --- Task 16: Path A flow ---
$t16Root = New-TestFolder 't16'

# A fake $Ctx with the contract keys. Nothing in it points at a real file.
function New-T16Ctx {
    param([string] $PgHba = 'NOT_STANDARD', [string] $PgIdent = 'EXTRA_ENTRY', [string] $PgPassword = 'SET')
    $pg = [pscustomobject]@{
        Ok = $true; Code = ''; Detail = ''; Version = '15.8'; Major = 15
        BaseDir = 'C:\PG'; DataDir = 'C:\PG\data'; ServiceName = 'postgresql-x64-15'
        Psql = 'C:\PG\bin\psql.exe'; HbaPath = 'C:\PG\data\pg_hba.conf'; IdentPath = 'C:\PG\data\pg_ident.conf'; Port = 5432
    }
    $db = [pscustomobject]@{
        RootKey = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication'
        KeyPath = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication\DatabaseConfigurations\PostgreSql'
        ActiveConfiguration = 'PostgreSql'; HostName = '127.0.0.1'; Port = 5432; DatabaseName = 'VeeamBackup'
        UserName = ''; PasswordSet = $false; WindowsAuthRole = 'postgres'
        EntraIdHost = ''; EntraIdPort = $null; EntraIdPasswordSet = $false
    }
    return @{
        Config             = Get-DefaultConfig
        WorkRoot           = $t16Root
        Stamp              = '20261012-101500'
        RunDir             = ''
        Apply              = $true
        CreateRequested    = $false
        Vbr                = [pscustomobject]@{ Installed = $true; CorePath = 'C:\VBR'; Version = '12.3.2.3617' }
        Db                 = $db
        Em                 = $null
        LocalNames         = @('VBR01', '10.0.0.5')
        Pg                 = $pg
        Addresses          = @('127.0.0.1', '::1')
        SystemNames        = [pscustomobject]@{ English = 'SYSTEM@NT AUTHORITY'; Translated = 'SYSTEM@NT AUTHORITY'; IsAscii = $true }
        Account            = [pscustomobject]@{ Status = 'OK'; Info = $null; BlocksDb = $false }
        ServiceAccounts    = [pscustomobject]@{ MapNames = @(); Unresolved = @() }
        RequiredIdentNames = @('SYSTEM@NT AUTHORITY', 'svc_veeam@VBR01')
        Hba                = [pscustomobject]@{ Path = $pg.HbaPath; Bytes = [byte[]]@(35); Text = '#'; LineEnding = "`r`n"; HadBom = $false; Sddl = 'SDDL-HBA' }
        HbaLines           = @('host all all 127.0.0.1/32 scram-sha-256')
        HbaRules           = @()
        Ident              = [pscustomobject]@{ Path = $pg.IdentPath; Bytes = [byte[]]@(35); Text = '#'; LineEnding = "`n"; HadBom = $false; Sddl = 'SDDL-IDENT' }
        IdentLines         = @('veeam "Administrator@VBR01" postgres')
        IdentEntries       = @()
        State              = @{ RegistryAuth = 'WINDOWS'; SspiPassed = $true; DbAuth = 'WINDOWS'; PgHba = $PgHba; PgIdent = $PgIdent; PgPassword = $PgPassword; Backends = @() }
        HbaBackupPath      = ''
        IdentBackupPath    = ''
        Snapshot           = @()
        StopSet            = @()
        Stopped            = @()
        RegSnapshot        = @{}
        RegBackup          = $null
        StartUtc           = [DateTime]::MinValue
        LogOffset          = [long]0
        PasswordCleared    = $false
    }
}

# Mocks for every function Path A calls. Dot-source inside a child scope '& { }'.
# $calls records the order; Write-ConfFileAtomic and Clear-PostgresPassword also
# record the stage at the moment they run.
$t16Mocks = {
    $calls = New-Object System.Collections.ArrayList
    $sspiQueue = New-Object System.Collections.Queue
    $fake = @{ HealthOk = $true; ClearOk = $true; RemoveMarkerOk = $true; WriteThrows = ''; RestoreThrows = '' }
    function New-RunFolder { param($WorkRoot, $Stamp) [void]$calls.Add('New-RunFolder'); return (Join-Path $WorkRoot "runs\$Stamp") }
    function Backup-ConfFile { param($Path, $RunDir) [void]$calls.Add("Backup-ConfFile:$(Split-Path -Leaf $Path)"); return (Join-Path $RunDir ((Split-Path -Leaf $Path) + '.before')) }
    function Write-ChangeMarker { param($WorkRoot, $RunDir, $PathName, $Stage) [void]$calls.Add("Write-ChangeMarker:${PathName}:$Stage") }
    function Remove-ChangeMarker { param($WorkRoot) [void]$calls.Add('Remove-ChangeMarker'); return [bool]$fake.RemoveMarkerOk }
    function New-PgIdentText { param($Lines, $RequiredNames, $LineEnding, $Stamp) return "veeam `"SYSTEM@NT AUTHORITY`" postgres$LineEnding" }
    function New-PgHbaText { param($Lines, $LineEnding, $Stamp) return "host all all 127.0.0.1/32 sspi map=veeam$LineEnding" }
    function ConvertTo-Latin1Bytes { param($Text) return [System.Text.Encoding]::GetEncoding(28591).GetBytes($Text) }
    function Get-NonLoopbackHbaRules { param($Rules) return @($Rules | Where-Object { "$($_.Type)" -like 'host*' -and @('127.0.0.1/32', '::1/128') -notcontains "$($_.Address)" }) }
    function Write-ConfFileAtomic {
        param($Path, $Bytes, $ExpectedSddl)
        [void]$calls.Add("Write-ConfFileAtomic:$(Split-Path -Leaf $Path):${ExpectedSddl}:$script:Stage")
        if ($fake.WriteThrows) { throw $fake.WriteThrows }
    }
    function Restore-ConfFile {
        param($Path, $BackupPath, $ExpectedSddl)
        [void]$calls.Add("Restore-ConfFile:$(Split-Path -Leaf $Path):$(Split-Path -Leaf $BackupPath):$ExpectedSddl")
        if ($fake.RestoreThrows -and (Split-Path -Leaf $Path) -eq $fake.RestoreThrows) { throw 'restore failed' }
    }
    function Test-PgSspiLogin {
        param($Psql, $Port, $Addresses, $Database)
        [void]$calls.Add('Test-PgSspiLogin')
        $passed = $true
        if ($sspiQueue.Count -gt 0) { $passed = [bool]$sspiQueue.Dequeue() }
        $kind = 'OK'
        if (-not $passed) { $kind = 'AUTH' }
        return [pscustomobject]@{ Passed = $passed; Results = @([pscustomobject]@{ Address = '127.0.0.1'; ExitCode = 2; Kind = $kind; StdErr = 'no match in usermap' }) }
    }
    function Test-PgConfigHealth { param($Psql, $Port, $Address, $Database, $Major, $HbaPath, $IdentPath) [void]$calls.Add('Test-PgConfigHealth'); return [pscustomobject]@{ Ok = [bool]$fake.HealthOk; Detail = 'pg_hba_file_rules has 1 error' } }
    function Clear-PostgresPassword { param($Psql, $Port, $Address, $Database) [void]$calls.Add("Clear-PostgresPassword:$script:Stage"); return [pscustomobject]@{ Ok = [bool]$fake.ClearOk; Detail = 'ALTER ROLE failed' } }
}

# Clear-PathFixedIssues: removes only the drift a finished path fixed.
& {
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'APPLY'
    foreach ($code in @('SVC_DISABLED', 'DB_NATIVE_AUTH', 'DB_HOST_NOT_LOCAL', 'DB_WINDOWS_ROLE_NOT_POSTGRES', 'PG_HBA_NOT_STANDARD', 'PG_IDENT_NOT_STANDARD', 'PG_POSTGRES_PASSWORD_SET')) {
        $null = Add-RunIssue -Code $code -ExitCode 5 -Detail 'test'
    }
    $ctx = New-T16Ctx -PgPassword 'SET'
    Clear-PathFixedIssues -Ctx $ctx
    Check 'T16 fixed drift removed, password issue kept' ((@($script:Issues) | ForEach-Object { $_.Code }) -join ',') 'SVC_DISABLED,PG_POSTGRES_PASSWORD_SET'
    Check 'T16 state PgHba STANDARD after fix' $ctx.State['PgHba'] 'STANDARD'
    Check 'T16 report DbAuth WINDOWS after fix' $script:Report['DbAuth'] 'WINDOWS'
    Check 'T16 report PgPassword unchanged while not cleared' $script:Report['PgPassword'] 'SET'
    $ctx.PasswordCleared = $true
    Clear-PathFixedIssues -Ctx $ctx -IncludePassword
    Check 'T16 -IncludePassword removes PG_POSTGRES_PASSWORD_SET' ((@($script:Issues) | ForEach-Object { $_.Code }) -join ',') 'SVC_DISABLED'
    Check 'T16 report PgPassword NONE when cleared' $script:Report['PgPassword'] 'NONE'
}

# Happy path: both files drift and the password is set.
& {
    . $t16Mocks
    $script:Stage = 'UNTOUCHED'
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'APPLY'
    foreach ($code in @('SVC_DISABLED', 'PG_HBA_NOT_STANDARD', 'PG_IDENT_NOT_STANDARD', 'PG_POSTGRES_PASSWORD_SET')) { $null = Add-RunIssue -Code $code -ExitCode 5 -Detail 'test' }
    $ctx = New-T16Ctx
    $result = Invoke-PathA -Ctx $ctx
    Check 'T16 happy: exit 0' $result.ExitCode 0
    Check 'T16 happy: no issue code' $result.Code ''
    Check 'T16 happy: spec order (backup, marker, ident, hba, test, marker off, password)' ($calls -join ' > ') ('New-RunFolder > Backup-ConfFile:pg_hba.conf > Backup-ConfFile:pg_ident.conf > Write-ChangeMarker:A:PATH_A_WRITING > ' +
        'Write-ConfFileAtomic:pg_ident.conf:SDDL-IDENT:PATH_A_WRITING > Write-ConfFileAtomic:pg_hba.conf:SDDL-HBA:PATH_A_WRITING > ' +
        'Test-PgSspiLogin > Test-PgConfigHealth > Remove-ChangeMarker > Clear-PostgresPassword:PATH_A_DONE')
    Check 'T16 happy: stage PATH_A_DONE' $script:Stage 'PATH_A_DONE'
    Check 'T16 happy: run folder recorded' $ctx.RunDir (Join-Path $t16Root 'runs\20261012-101500')
    Check 'T16 happy: pg_hba backup recorded' $ctx.HbaBackupPath (Join-Path $t16Root 'runs\20261012-101500\pg_hba.conf.before')
    Check 'T16 happy: pg_ident backup recorded' $ctx.IdentBackupPath (Join-Path $t16Root 'runs\20261012-101500\pg_ident.conf.before')
    Check 'T16 happy: PasswordCleared set' $ctx.PasswordCleared 'True'
    Check 'T16 happy: only the account issue is left' ((@($script:Issues) | ForEach-Object { $_.Code }) -join ',') 'SVC_DISABLED'
    Check 'T16 happy: report PgHba' $script:Report['PgHba'] 'STANDARD'
    Check 'T16 happy: report PgIdent' $script:Report['PgIdent'] 'STANDARD'
    Check 'T16 happy: report PgPassword' $script:Report['PgPassword'] 'NONE'
    Check 'T16 happy: detail names the run folder' ($result.Detail -like "*$(Join-Path $t16Root 'runs\20261012-101500')*") 'True'
}

# Files already standard, only the password is set: no backup, no marker, no write.
& {
    . $t16Mocks
    $script:Stage = 'UNTOUCHED'
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'APPLY'
    $ctx = New-T16Ctx -PgHba 'STANDARD' -PgIdent 'STANDARD' -PgPassword 'SET'
    $result = Invoke-PathA -Ctx $ctx
    Check 'T16 password only: exit 0' $result.ExitCode 0
    Check 'T16 password only: calls' ($calls -join ' > ') 'Clear-PostgresPassword:PATH_A_DONE'
}

# Only pg_hba.conf drifts; a LAN line is listed in Detail and the log.
& {
    . $t16Mocks
    $script:Stage = 'UNTOUCHED'
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'APPLY'
    $script:LogLines.Clear()
    $ctx = New-T16Ctx -PgHba 'NOT_STANDARD' -PgIdent 'STANDARD' -PgPassword 'NONE'
    $ctx.HbaRules = @(
        [pscustomobject]@{ LineIndex = 3; Type = 'host'; Database = 'all'; User = 'all'; Address = '127.0.0.1/32'; Method = 'scram-sha-256'; Options = '' },
        [pscustomobject]@{ LineIndex = 94; Type = 'host'; Database = 'all'; User = 'all'; Address = '10.0.0.0/8'; Method = 'scram-sha-256'; Options = '' }
    )
    $result = Invoke-PathA -Ctx $ctx
    Check 'T16 hba only: exit 0' $result.ExitCode 0
    Check 'T16 hba only: one write, pg_hba.conf' (@($calls | Where-Object { $_ -like 'Write-ConfFileAtomic:*' }) -join ',') 'Write-ConfFileAtomic:pg_hba.conf:SDDL-HBA:PATH_A_WRITING'
    Check 'T16 hba only: LAN line in Detail' ($result.Detail -like '*line 95: host all all 10.0.0.0/8 scram-sha-256*') 'True'
    Check 'T16 hba only: LAN line logged as WARN' (@($script:LogLines | Where-Object { $_ -like '`[WARN`]*10.0.0.0/8*' }).Count) 1
    Check 'T16 hba only: no password step' (@($calls | Where-Object { $_ -like 'Clear-PostgresPassword*' }).Count) 0
}

# SSPI test fails after the write; the restore brings SSPI back -> 40, marker removed.
& {
    . $t16Mocks
    $script:Stage = 'UNTOUCHED'
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'APPLY'
    $null = Add-RunIssue -Code 'PG_HBA_NOT_STANDARD' -ExitCode 5 -Detail 'test'
    $sspiQueue.Enqueue($false)
    $sspiQueue.Enqueue($true)
    $ctx = New-T16Ctx
    $result = Invoke-PathA -Ctx $ctx
    Check 'T16 test fails, restore ok: exit 40' $result.ExitCode 40
    Check 'T16 test fails, restore ok: code' $result.Code 'PG_SSPI_TEST_FAILED'
    $afterFirstTest = @($calls)[(@($calls).IndexOf('Test-PgSspiLogin') + 1)..(@($calls).Count - 1)] -join ' > '
    Check 'T16 test fails, restore ok: restore ident, hba, test, marker off' $afterFirstTest ('Restore-ConfFile:pg_ident.conf:pg_ident.conf.before:SDDL-IDENT > ' +
        'Restore-ConfFile:pg_hba.conf:pg_hba.conf.before:SDDL-HBA > Test-PgSspiLogin > Test-PgConfigHealth > Remove-ChangeMarker')
    Check 'T16 test fails, restore ok: no password step' (@($calls | Where-Object { $_ -like 'Clear-PostgresPassword*' }).Count) 0
    Check 'T16 test fails, restore ok: stage stays PATH_A_WRITING' $script:Stage 'PATH_A_WRITING'
    Check 'T16 test fails, restore ok: drift issue kept' ((@($script:Issues) | ForEach-Object { $_.Code }) -join ',') 'PG_HBA_NOT_STANDARD'
}

# Config check fails and SSPI still fails after the restore -> 50, marker stays.
& {
    . $t16Mocks
    $script:Stage = 'UNTOUCHED'
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'APPLY'
    $fake.HealthOk = $false
    $sspiQueue.Enqueue($true)
    $sspiQueue.Enqueue($false)
    $result = Invoke-PathA -Ctx (New-T16Ctx)
    Check 'T16 restore fails: exit 50' $result.ExitCode 50
    Check 'T16 restore fails: code' $result.Code 'ROLLBACK_FAILED'
    Check 'T16 restore fails: detail keeps the first failure' ($result.Detail -like 'PG_SSPI_TEST_FAILED:*pg_hba_file_rules has 1 error*') 'True'
    Check 'T16 restore fails: marker not removed' (@($calls | Where-Object { $_ -eq 'Remove-ChangeMarker' }).Count) 0
    Check 'T16 restore fails: action pages' ($result.Action -like 'PAGE AN OPERATOR*') 'True'
}

# Clearing the password fails after verified files -> 5 PG_PASSWORD_NOT_CLEARED.
& {
    . $t16Mocks
    $script:Stage = 'UNTOUCHED'
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'APPLY'
    $null = Add-RunIssue -Code 'PG_POSTGRES_PASSWORD_SET' -ExitCode 5 -Detail 'test'
    $fake.ClearOk = $false
    $ctx = New-T16Ctx
    $result = Invoke-PathA -Ctx $ctx
    Check 'T16 password not cleared: exit 5' $result.ExitCode 5
    Check 'T16 password not cleared: code' $result.Code 'PG_PASSWORD_NOT_CLEARED'
    Check 'T16 password not cleared: stage PATH_A_DONE' $script:Stage 'PATH_A_DONE'
    Check 'T16 password not cleared: PasswordCleared false' $ctx.PasswordCleared 'False'
    Check 'T16 password not cleared: replaces PG_POSTGRES_PASSWORD_SET' @($script:Issues).Count 0
}

# The marker cannot be removed after a verified write -> still 0, plus a 5 issue.
& {
    . $t16Mocks
    $script:Stage = 'UNTOUCHED'
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'APPLY'
    $fake.RemoveMarkerOk = $false
    $result = Invoke-PathA -Ctx (New-T16Ctx -PgPassword 'NONE')
    Check 'T16 marker stuck: path result 0' $result.ExitCode 0
    Check 'T16 marker stuck: POST_CONVERSION_STEP_FAILED added' ((@($script:Issues) | ForEach-Object { "$($_.Code)/$($_.ExitCode)" }) -join ',') 'POST_CONVERSION_STEP_FAILED/5'
}

# An unexpected write error is left to the trap, with the stage that makes it restore.
& {
    . $t16Mocks
    $script:Stage = 'UNTOUCHED'
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'APPLY'
    $fake.WriteThrows = 'The process cannot access the file'
    Throws 'T16 write error reaches the trap' { Invoke-PathA -Ctx (New-T16Ctx) }
    Check 'T16 write error: stage is PATH_A_WRITING for the trap' $script:Stage 'PATH_A_WRITING'
    Check 'T16 write error: marker was written before the write' (@($calls).IndexOf('Write-ChangeMarker:A:PATH_A_WRITING') -lt @($calls).IndexOf('Write-ConfFileAtomic:pg_ident.conf:SDDL-IDENT:PATH_A_WRITING')) 'True'
}

# Both texts are rendered first: a name that cannot be written as ASCII stops Path A
# before the backup and the marker, so the trap has nothing to restore.
& {
    . $t16Mocks
    $script:Stage = 'UNTOUCHED'
    function New-PgIdentText { param($Lines, $RequiredNames, $LineEnding, $Stamp) throw 'New-PgIdentText: the name is not printable ASCII' }
    Throws 'T16 render error reaches the trap' { Invoke-PathA -Ctx (New-T16Ctx) }
    Check 'T16 render error: no run folder, backup, marker or write' (@($calls | Where-Object { $_ -like 'New-RunFolder*' -or $_ -like 'Backup-ConfFile*' -or $_ -like 'Write-ChangeMarker*' -or $_ -like 'Write-ConfFileAtomic*' }).Count) 0
    Check 'T16 render error: stage stays UNTOUCHED' $script:Stage 'UNTOUCHED'
}

# Restore-PathAFiles on its own.
& {
    . $t16Mocks
    $ctx = New-T16Ctx
    $ctx.HbaBackupPath = 'C:\runs\x\pg_hba.conf.before'
    $ctx.IdentBackupPath = 'C:\runs\x\pg_ident.conf.before'
    Check 'T16 restore: both restored and SSPI ok -> True' (Restore-PathAFiles -Ctx $ctx) 'True'
    Check 'T16 restore: ident first, then hba, then the SSPI test and config check' ($calls -join ' > ') ('Restore-ConfFile:pg_ident.conf:pg_ident.conf.before:SDDL-IDENT > ' +
        'Restore-ConfFile:pg_hba.conf:pg_hba.conf.before:SDDL-HBA > Test-PgSspiLogin > Test-PgConfigHealth')
    $calls.Clear()
    $fake.HealthOk = $false
    Check 'T16 restore: config check failing after the restore -> False' (Restore-PathAFiles -Ctx $ctx) 'False'
    $fake.HealthOk = $true
    $calls.Clear()
    $fake.RestoreThrows = 'pg_ident.conf'
    Check 'T16 restore: a failed file -> False' (Restore-PathAFiles -Ctx $ctx) 'False'
    Check 'T16 restore: the other file is still restored' (@($calls | Where-Object { $_ -like 'Restore-ConfFile:pg_hba.conf*' }).Count) 1
    $calls.Clear()
    $fake.RestoreThrows = ''
    $ctx.IdentBackupPath = ''
    Check 'T16 restore: missing backup -> False' (Restore-PathAFiles -Ctx $ctx) 'False'
    Check 'T16 restore: nothing restored without a backup path' (@($calls | Where-Object { $_ -like 'Restore-ConfFile:pg_ident.conf*' }).Count) 0
    $calls.Clear()
    $ctx.IdentBackupPath = 'C:\runs\x\pg_ident.conf.before'
    $sspiQueue.Enqueue($false)
    Check 'T16 restore: SSPI still failing -> False' (Restore-PathAFiles -Ctx $ctx) 'False'
}
$script:Stage = 'UNTOUCHED'
$script:Issues = New-Object System.Collections.ArrayList
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: the checks of earlier tasks print `PASS`. The harness trap from Task 1 turns each Task 16 block that calls a missing function into one line `  FAIL  UNHANDLED  The term '<name>' is not recognized as the name of a cmdlet, function, script file, or operable program.` followed by the PowerShell spelling hint: first for `Clear-PathFixedIssues`, then seven times for `Invoke-PathA`, and last for `Restore-PathAFiles`. `T16 write error: stage is PATH_A_WRITING for the trap` and `T16 write error: marker was written before the write` also FAIL. Four Task 16 checks pass without the code, because calling a missing function throws and records nothing: `T16 write error reaches the trap` and the three `T16 render error` checks. The run ends with `RESULT: <n> passed, 11 failed`, where `<n>` is the Task 15 total plus 4 (`RESULT: 1172 passed, 11 failed` on an elevated prompt on English Windows without PostgreSQL or VBR), and exit code 1.

- [ ] **Step 3: Implement**

Insert this code just above the line `#endregion PathA` in `Invoke-VbrStandardise.ps1`:

```powershell
# A path that reached its safe end (stage PATH_A_DONE or VERIFIED) has fixed the
# database drift that the audit reported. Remove those issues, so the RMM summary
# does not list drift that no longer exists, and report the new state.
# -IncludePassword also removes PG_POSTGRES_PASSWORD_SET: the path either cleared
# the password, or reports PG_PASSWORD_NOT_CLEARED in its place.
function Clear-PathFixedIssues {
    param(
        [Parameter(Mandatory)][hashtable] $Ctx,
        [switch] $IncludePassword
    )
    $fixedCodes = @('DB_NATIVE_AUTH', 'DB_HOST_NOT_LOCAL', 'DB_WINDOWS_ROLE_NOT_POSTGRES',
                    'PG_HBA_NOT_STANDARD', 'PG_IDENT_NOT_STANDARD')
    if ($IncludePassword) { $fixedCodes += 'PG_POSTGRES_PASSWORD_SET' }

    $issuesVar = Get-Variable -Name Issues -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $issuesVar -and $issuesVar.Value -is [System.Collections.ArrayList]) {
        $issueList = $issuesVar.Value
        foreach ($issue in @($issueList)) {
            if ($null -ne $issue -and $fixedCodes -contains "$($issue.Code)") { $issueList.Remove($issue) }
        }
    }

    $state = $Ctx['State']
    if ($state -isnot [hashtable]) {
        $state = @{}
        $Ctx['State'] = $state
    }
    $state['DbAuth'] = 'WINDOWS'
    $state['PgHba'] = 'STANDARD'
    $state['PgIdent'] = 'STANDARD'
    if ([bool]$Ctx['PasswordCleared']) { $state['PgPassword'] = 'NONE' }

    $reportVar = Get-Variable -Name Report -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $reportVar -and $reportVar.Value -is [System.Collections.IDictionary]) {
        $report = $reportVar.Value
        $report['DbAuth'] = 'WINDOWS'
        $report['PgHba'] = 'STANDARD'
        $report['PgIdent'] = 'STANDARD'
        if ($state.ContainsKey('PgPassword')) { $report['PgPassword'] = "$($state['PgPassword'])" }
    }
}

# Spec 7.8 restore for Path A (also used by the trap at stage PATH_A_WRITING).
# Writes the run-folder backup bytes back with Restore-ConfFile (the same atomic
# routine as every write, never a move or copy), pg_ident.conf first, then
# repeats the SSPI test. Returns $true only when both files were restored and
# SYSTEM can log in again on every listening loopback address. Never throws.
function Restore-PathAFiles {
    param([Parameter(Mandatory)][hashtable] $Ctx)
    $allRestored = $true
    $files = @(
        @{ Name = 'pg_ident.conf'; Live = "$($Ctx.Pg.IdentPath)"; Backup = "$($Ctx['IdentBackupPath'])"; Sddl = "$($Ctx.Ident.Sddl)" },
        @{ Name = 'pg_hba.conf';   Live = "$($Ctx.Pg.HbaPath)";   Backup = "$($Ctx['HbaBackupPath'])";   Sddl = "$($Ctx.Hba.Sddl)" }
    )
    foreach ($file in $files) {
        if ([string]::IsNullOrEmpty($file.Backup)) {
            Write-Log "No backup of $($file.Name) is recorded, so it cannot be restored." -Level ERROR
            $allRestored = $false
            continue
        }
        try {
            $null = Restore-ConfFile -Path $file.Live -BackupPath $file.Backup -ExpectedSddl $file.Sddl
            Write-Log "Restored $($file.Name) from $($file.Backup)" -Level OK
        } catch {
            Write-Log "Restoring $($file.Name) failed: $($_.Exception.Message)" -Level ERROR
            $allRestored = $false
        }
    }

    $loginPassed = $false
    try {
        $test = Test-PgSspiLogin -Psql "$($Ctx.Pg.Psql)" -Port ([int]$Ctx.Pg.Port) -Addresses @($Ctx.Addresses) -Database "$($Ctx.Db.DatabaseName)"
        $loginPassed = [bool]$test.Passed
        if (-not $loginPassed) {
            foreach ($result in @($test.Results | Where-Object { $null -ne $_ -and "$($_.Kind)" -ne 'OK' })) {
                Write-Log "SSPI test after the restore: $($result.Address) $($result.Kind) $($result.StdErr)" -Level ERROR
            }
        }
    } catch {
        Write-Log "SSPI test after the restore failed to run: $($_.Exception.Message)" -Level ERROR
        $loginPassed = $false
    }

    # Spec 7.6 Path A step 3: "test again" means all of section 7.9, so the
    # config check runs too once the login works.
    $healthOk = $false
    if ($loginPassed) {
        try {
            $healthAddresses = @($Ctx.Addresses)
            $health = Test-PgConfigHealth -Psql "$($Ctx.Pg.Psql)" -Port ([int]$Ctx.Pg.Port) -Address "$($healthAddresses[0])" -Database "$($Ctx.Db.DatabaseName)" -Major ([int]$Ctx.Pg.Major) -HbaPath "$($Ctx.Pg.HbaPath)" -IdentPath "$($Ctx.Pg.IdentPath)"
            $healthOk = [bool]$health.Ok
            if (-not $healthOk) {
                Write-Log "Config check after the restore: $($health.Detail)" -Level ERROR
            }
        } catch {
            Write-Log "Config check after the restore failed to run: $($_.Exception.Message)" -Level ERROR
            $healthOk = $false
        }
    }
    return ($allRestored -and $loginPassed -and $healthOk)
}

# Spec 7.6 Path A: VBR already uses Windows authentication, so SYSTEM logs in to
# postgres before and after the change and no service is stopped.
# Returns { ExitCode; Code; Detail; Action } (Code '' and Action '' mean success and
# the default RMM action). An unexpected error, for example from Write-ConfFileAtomic,
# is not caught here: it reaches the trap, which restores both files because the
# stage is PATH_A_WRITING.
function Invoke-PathA {
    param([Parameter(Mandatory)][hashtable] $Ctx)
    $state = $Ctx['State']
    $writeIdent = ("$($state['PgIdent'])" -ne 'STANDARD')
    $writeHba = ("$($state['PgHba'])" -ne 'STANDARD')
    $psql = "$($Ctx.Pg.Psql)"
    $port = [int]$Ctx.Pg.Port
    $addresses = @($Ctx.Addresses)
    $database = "$($Ctx.Db.DatabaseName)"
    $notes = New-Object System.Collections.ArrayList

    if ($writeIdent -or $writeHba) {
        # Render both new texts before the backup and the marker (Task 10): a name that
        # cannot be written as ASCII then stops the run here, at stage UNTOUCHED, with
        # nothing changed.
        $identText = ''
        $hbaText = ''
        if ($writeIdent) { $identText = New-PgIdentText -Lines @($Ctx.IdentLines) -RequiredNames @($Ctx.RequiredIdentNames) -LineEnding $Ctx.Ident.LineEnding -Stamp $Ctx.Stamp }
        if ($writeHba) { $hbaText = New-PgHbaText -Lines @($Ctx.HbaLines) -LineEnding $Ctx.Hba.LineEnding -Stamp $Ctx.Stamp }

        Write-Log 'Path A step 1 - back up pg_hba.conf and pg_ident.conf, then write the marker' -Level STEP
        $Ctx['RunDir'] = New-RunFolder -WorkRoot $Ctx.WorkRoot -Stamp $Ctx.Stamp
        $Ctx['HbaBackupPath'] = Backup-ConfFile -Path $Ctx.Pg.HbaPath -RunDir $Ctx.RunDir
        $Ctx['IdentBackupPath'] = Backup-ConfFile -Path $Ctx.Pg.IdentPath -RunDir $Ctx.RunDir
        Write-Log "pg_hba.conf SDDL before the change: $($Ctx.Hba.Sddl)"
        Write-Log "pg_ident.conf SDDL before the change: $($Ctx.Ident.Sddl)"
        $null = Write-ChangeMarker -WorkRoot $Ctx.WorkRoot -RunDir $Ctx.RunDir -PathName 'A' -Stage 'PATH_A_WRITING'
        $script:Stage = 'PATH_A_WRITING'

        Write-Log 'Path A step 2 - write the files that are not standard' -Level STEP
        if ($writeIdent) {
            $null = Write-ConfFileAtomic -Path $Ctx.Pg.IdentPath -Bytes (ConvertTo-Latin1Bytes -Text $identText) -ExpectedSddl $Ctx.Ident.Sddl
            Write-Log "Wrote $($Ctx.Pg.IdentPath)" -Level OK
        }
        if ($writeHba) {
            $hbaRules = @($Ctx.HbaRules | Where-Object { $null -ne $_ })
            if ($hbaRules.Count -gt 0) {
                foreach ($rule in @(Get-NonLoopbackHbaRules -Rules $hbaRules)) {
                    $ruleText = "line $([int]$rule.LineIndex + 1): $($rule.Type) $($rule.Database) $($rule.User) $($rule.Address) $($rule.Method)"
                    Write-Log "pg_hba.conf line for another address is commented out: $ruleText" -Level WARN
                    [void]$notes.Add("Commented out pg_hba.conf $ruleText.")
                }
            }
            $null = Write-ConfFileAtomic -Path $Ctx.Pg.HbaPath -Bytes (ConvertTo-Latin1Bytes -Text $hbaText) -ExpectedSddl $Ctx.Hba.Sddl
            Write-Log "Wrote $($Ctx.Pg.HbaPath)" -Level OK
        }

        Write-Log 'Path A step 3 - SSPI test as SYSTEM and PostgreSQL config check' -Level STEP
        $failure = ''
        $sspi = Test-PgSspiLogin -Psql $psql -Port $port -Addresses $addresses -Database $database
        if (-not $sspi.Passed) {
            $failed = @($sspi.Results | Where-Object { $null -ne $_ -and "$($_.Kind)" -ne 'OK' } | ForEach-Object { "$($_.Address) $($_.Kind) $($_.StdErr)" })
            $failure = 'SSPI login as SYSTEM failed after the write: ' + ($failed -join '; ')
        } else {
            $health = Test-PgConfigHealth -Psql $psql -Port $port -Address $addresses[0] -Database $database -Major ([int]$Ctx.Pg.Major) -HbaPath "$($Ctx.Pg.HbaPath)" -IdentPath "$($Ctx.Pg.IdentPath)"
            if (-not $health.Ok) { $failure = "PostgreSQL reports a problem with the new files: $($health.Detail)" }
        }
        if ($failure) {
            Write-Log $failure -Level ERROR
            if (Restore-PathAFiles -Ctx $Ctx) {
                $markerNote = ''
                if (-not (Remove-ChangeMarker -WorkRoot $Ctx.WorkRoot)) {
                    $markerNote = " The marker could not be removed: delete $(Join-Path $Ctx.WorkRoot 'CHANGES-IN-PROGRESS.marker') after checking the files."
                }
                return [pscustomobject]@{
                    ExitCode = 40
                    Code     = 'PG_SSPI_TEST_FAILED'
                    Detail   = "$failure; both files were restored from $($Ctx.RunDir) and SYSTEM can log in again.$markerNote"
                    Action   = ''
                }
            }
            return [pscustomobject]@{
                ExitCode = 50
                Code     = 'ROLLBACK_FAILED'
                Detail   = "PG_SSPI_TEST_FAILED: $failure; after restoring both files from $($Ctx.RunDir) SYSTEM still cannot log in. The marker stays."
                Action   = 'PAGE AN OPERATOR NOW. VBR may not be able to open new database connections. Follow the MARKER_PRESENT recovery steps in README.md.'
            }
        }
        [void]$notes.Add("pg_hba.conf and pg_ident.conf are standard now. Backups: $($Ctx.RunDir).")
    }

    Write-Log 'Path A step 4 - the files are verified; remove the marker' -Level STEP
    $script:Stage = 'PATH_A_DONE'
    if ($writeIdent -or $writeHba) {
        if (-not (Remove-ChangeMarker -WorkRoot $Ctx.WorkRoot)) {
            $null = Add-RunIssue -Code 'POST_CONVERSION_STEP_FAILED' -ExitCode 5 -Detail "The change worked, but the marker could not be removed: $(Join-Path $Ctx.WorkRoot 'CHANGES-IN-PROGRESS.marker')" -Action 'Delete the marker file named in Detail, then re-run'
        }
    }
    Clear-PathFixedIssues -Ctx $Ctx

    if ("$($state['PgPassword'])" -eq 'SET') {
        Write-Log 'Path A step 5 - clear the postgres password' -Level STEP
        $clear = Clear-PostgresPassword -Psql $psql -Port $port -Address $addresses[0] -Database $database
        if (-not $clear.Ok) {
            Clear-PathFixedIssues -Ctx $Ctx -IncludePassword
            return [pscustomobject]@{
                ExitCode = 5
                Code     = 'PG_PASSWORD_NOT_CLEARED'
                Detail   = "VBR works with Windows authentication, but the postgres password could not be cleared: $($clear.Detail) $($notes -join ' ')"
                Action   = 'Re-run with -Apply to clear the postgres password'
            }
        }
        $Ctx['PasswordCleared'] = $true
        Clear-PathFixedIssues -Ctx $Ctx -IncludePassword
        [void]$notes.Add('The postgres password was cleared.')
        Write-Log 'The postgres password is cleared.' -Level OK
    }
    return [pscustomobject]@{ ExitCode = 0; Code = ''; Detail = ($notes -join ' '); Action = '' }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: <n> passed, 0 failed`, where `<n>` is the total after Task 15 plus 58 (`RESULT: 1226 passed, 0 failed` on an elevated prompt on English Windows without PostgreSQL or VBR). Exit code 0.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add Path A: standardise the config files while VBR runs" -m "Path A backs up pg_hba.conf and pg_ident.conf, writes the marker before the first write, writes only the drifted files, then tests SSPI and the config views. On a failed test it restores both files and exits 40, or 50 if SSPI still fails. The postgres password is cleared only after the files are verified. Clear-PathFixedIssues drops the drift a verified path fixed, so the RMM summary stays honest." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 17: Path B flow and rollback

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region PathB)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Write-Log`, `Get-CfgValue`, `Format-ShortText`, `Write-AtomicJson` (Task 1); `New-RunReport` (tests), `Add-RunIssue` (Task 2); `Test-LastFailure`, `Write-LastFailure`, `New-RunFolder`, `Write-ChangeMarker`, `Remove-ChangeMarker` (Task 3); `ConvertTo-Latin1Bytes`, `Write-ConfFileAtomic`, `Backup-ConfFile`, `Restore-ConfFile` (Task 8); `Get-NonLoopbackHbaRules`, `New-PgHbaText` (Task 9); `New-PgIdentText` (Task 10); `Test-PgSspiLogin`, `Test-PgConfigHealth`, `Clear-PostgresPassword`, `Get-OtherPasswordRoles` (Task 11); `Get-BusyVeeamWork`, `Get-VeeamServiceSnapshot`, `Get-StopSet`, `Get-ExternalDependents`, `Get-StartOrder`, `Stop-ServicesBounded`, `Start-ServicesBounded`, `Test-ServiceStaysRunning` (Task 13); `Get-RegistryValueSnapshot`, `ConvertTo-RegExePath`, `Save-RegistryBackup`, `Get-RegistryTargets`, `Set-RegistryTargets`, `Restore-RegistrySnapshot` (Task 14); `Get-FileLength`, `Read-LogTail`, `Find-AuthErrors`, `Wait-VbrDbConnected` (Task 15); `Clear-PathFixedIssues` and the test helper `New-T16Ctx` (Task 16).
- Produces:
  - `Invoke-PathB -Ctx <hashtable>` → `{ ExitCode:int; Code:string; Detail:string; Action:string }`. Sets `$script:Stage` (`PATH_B_CHANGING` right after the marker, back to `UNTOUCHED` when it stops before any change, `VERIFIED` after the connect check). Results: 0; 5 `PATH_B_PREVIOUS_FAILURE`, `VEEAM_BUSY_PERSISTENT`, `SERVICE_DEPENDENT_OUTSIDE_SET`, `PG_PASSWORD_NOT_CLEARED`, `POST_CONVERSION_STEP_FAILED`; 10 `VEEAM_BUSY`, `SERVICES_WONT_STOP`; 40/50 from `Invoke-PathBRollback`; 50 `ROLLBACK_FAILED` when a service that this run stopped does not start again after `SERVICES_WONT_STOP`. Fills `$Ctx` keys `Snapshot`, `StopSet`, `Stopped`, `RunDir`, `HbaBackupPath`, `IdentBackupPath`, `RegSnapshot`, `RegBackup`, `StartUtc`, `LogOffset`, `PasswordCleared`. Writes `services-before.json` to the run folder for manual recovery. Both new texts are rendered before step 4, so a `New-PgIdentText` throw (a name that is not ASCII, Task 10) reaches the trap with stage `UNTOUCHED`: no backup, no marker, no service stopped.
  - `Invoke-PathBRollback -Ctx <hashtable> -Reason <string>` → `{ ExitCode:int; Code:string; Detail:string; Action:string }`. `Reason` starts with the issue code of the failure, for example `VBR_DB_CONNECT_FAILED: no new VBR backend`. 40 returns that code (`UNHANDLED_ERROR` when `Reason` has none); 50 returns `ROLLBACK_FAILED`. Always writes `last-failure.json`; removes the marker only on 40; never throws.

- [ ] **Step 1: Write the failing tests**

Insert this block just above the line `# ===================== RESULT =====================` in `Test-VbrStandardise.ps1`. `$t17Mocks` replaces every function Path B and its rollback call, plus `Get-Process` and `Get-Service`, and records the calls in order with the stage at the time of each stop, write and registry change.

```powershell
# --- Task 17: Path B flow and rollback ---
# A native-auth server: registry has a user and password, SYSTEM cannot log in yet.
function New-T17Ctx {
    $ctx = New-T16Ctx -PgHba 'NOT_STANDARD' -PgIdent 'MISSING_ENTRY' -PgPassword 'UNKNOWN'
    $ctx.State['RegistryAuth'] = 'NATIVE'
    $ctx.State['DbAuth'] = 'NATIVE'
    $ctx.State['SspiPassed'] = $false
    $ctx.Db.UserName = 'postgres'
    $ctx.Db.PasswordSet = $true
    return $ctx
}

# Mocks for every function Path B and its rollback call, plus Get-Process and
# Get-Service so nothing real is read. Dot-source inside '& { }'.
$t17Mocks = {
    $calls = New-Object System.Collections.ArrayList
    $sspiQueue = New-Object System.Collections.Queue
    $busyQueue = New-Object System.Collections.Queue
    $startQueue = New-Object System.Collections.Queue
    $fake = @{
        LastFailure = $false; External = @(); NotStopped = @(); HealthOk = $true; ConnectOk = $true
        ClearOk = $true; OtherRoles = @('pg_native_admin'); RegRestoreOk = $true; SettleOk = $true
        LogLines = @(); AuthErrors = @(); WriteThrows = ''; LastFailureReason = ''; RemoveMarkerOk = $true
    }
    function Get-Process { [CmdletBinding()] param([string[]] $Name) }
    function Get-Service { [CmdletBinding()] param([string[]] $Name) }
    function Test-LastFailure { param($WorkRoot) [void]$calls.Add('Test-LastFailure'); return [bool]$fake.LastFailure }
    function Get-BusyVeeamWork {
        param($Processes, $Now, $PersistentHours)
        [void]$calls.Add('Get-BusyVeeamWork')
        if ($busyQueue.Count -gt 0) { return $busyQueue.Dequeue() }
        return [pscustomobject]@{ Busy = $false; Persistent = $false; Names = @() }
    }
    function Get-VeeamServiceSnapshot {
        [void]$calls.Add('Get-VeeamServiceSnapshot')
        return @(
            [pscustomobject]@{ Name = 'VeeamBackupSvc'; Status = 'Running'; StartType = 'Automatic'; DependsOn = @(); Dependents = @() },
            [pscustomobject]@{ Name = 'VeeamBrokerSvc'; Status = 'Running'; StartType = 'Automatic'; DependsOn = @(); Dependents = @() }
        )
    }
    function Get-StopSet { param($Snapshot) return @('VeeamBackupSvc', 'VeeamBrokerSvc') }
    function Get-ExternalDependents { param($StopSet, $AllServices) [void]$calls.Add('Get-ExternalDependents'); return @($fake.External) }
    function New-RunFolder { param($WorkRoot, $Stamp) [void]$calls.Add('New-RunFolder'); return (Join-Path $WorkRoot "runs\$Stamp") }
    function Backup-ConfFile { param($Path, $RunDir) [void]$calls.Add("Backup-ConfFile:$(Split-Path -Leaf $Path)"); return (Join-Path $RunDir ((Split-Path -Leaf $Path) + '.before')) }
    function Write-AtomicJson { param($Path, $Object) [void]$calls.Add("Write-AtomicJson:$(Split-Path -Leaf $Path):" + (@($Object['StopSet']) -join ',')) }
    function Get-RegistryValueSnapshot {
        param($KeyPath, $Names)
        [void]$calls.Add('Get-RegistryValueSnapshot:' + (@($Names) -join ','))
        return @{ SqlUserName = [pscustomobject]@{ Exists = $true; Kind = 'String'; Data = 'postgres' } }
    }
    function ConvertTo-RegExePath { param($KeyPath) return ($KeyPath -replace '^(HKLM|HKCU):', '$1') }
    function Save-RegistryBackup {
        param($KeyPath, $ExportKeyPath, $RunDir, $Snapshot)
        [void]$calls.Add("Save-RegistryBackup:$ExportKeyPath")
        return [pscustomobject]@{ JsonPath = (Join-Path $RunDir 'registry-before.json'); RegPath = (Join-Path $RunDir 'vbr-key.reg') }
    }
    function Write-ChangeMarker { param($WorkRoot, $RunDir, $PathName, $Stage) [void]$calls.Add("Write-ChangeMarker:${PathName}:$Stage") }
    function Remove-ChangeMarker { param($WorkRoot) [void]$calls.Add('Remove-ChangeMarker'); return [bool]$fake.RemoveMarkerOk }
    function Stop-ServicesBounded {
        param($Names, $TimeoutSec)
        [void]$calls.Add('Stop-ServicesBounded:' + (@($Names) -join ',') + ":$script:Stage")
        $notStopped = @($fake.NotStopped)
        return [pscustomobject]@{ Ok = ($notStopped.Count -eq 0); Stopped = @($Names | Where-Object { $notStopped -notcontains $_ }); NotStopped = $notStopped }
    }
    function Get-StartOrder { param($Snapshot, $Names) return @($Names) }
    function Start-ServicesBounded {
        param($Names, $TimeoutSec)
        [void]$calls.Add('Start-ServicesBounded:' + (@($Names) -join ','))
        $ok = $true
        if ($startQueue.Count -gt 0) { $ok = [bool]$startQueue.Dequeue() }
        $notStarted = @()
        if (-not $ok) { $notStarted = @(@($Names)[0]) }
        return [pscustomobject]@{ Ok = $ok; Started = @($Names | Where-Object { $notStarted -notcontains $_ }); NotStarted = $notStarted }
    }
    function New-PgIdentText { param($Lines, $RequiredNames, $LineEnding, $Stamp) return "veeam `"SYSTEM@NT AUTHORITY`" postgres$LineEnding" }
    function New-PgHbaText { param($Lines, $LineEnding, $Stamp) return "host all all 127.0.0.1/32 sspi map=veeam$LineEnding" }
    function ConvertTo-Latin1Bytes { param($Text) return [System.Text.Encoding]::GetEncoding(28591).GetBytes($Text) }
    function Get-NonLoopbackHbaRules { param($Rules) return @($Rules | Where-Object { "$($_.Type)" -like 'host*' -and @('127.0.0.1/32', '::1/128') -notcontains "$($_.Address)" }) }
    function Write-ConfFileAtomic {
        param($Path, $Bytes, $ExpectedSddl)
        [void]$calls.Add("Write-ConfFileAtomic:$(Split-Path -Leaf $Path):$script:Stage")
        if ($fake.WriteThrows) { throw $fake.WriteThrows }
    }
    function Test-PgSspiLogin {
        param($Psql, $Port, $Addresses, $Database)
        [void]$calls.Add('Test-PgSspiLogin')
        $passed = $true
        if ($sspiQueue.Count -gt 0) { $passed = [bool]$sspiQueue.Dequeue() }
        $kind = 'OK'
        if (-not $passed) { $kind = 'AUTH' }
        return [pscustomobject]@{ Passed = $passed; Results = @([pscustomobject]@{ Address = '127.0.0.1'; ExitCode = 2; Kind = $kind; StdErr = 'SSPI authentication failed' }) }
    }
    function Test-PgConfigHealth { param($Psql, $Port, $Address, $Database, $Major, $HbaPath, $IdentPath) [void]$calls.Add('Test-PgConfigHealth'); return [pscustomobject]@{ Ok = [bool]$fake.HealthOk; Detail = 'hba_file differs' } }
    function Get-RegistryTargets {
        param($DbConfig, $Addresses)
        [void]$calls.Add('Get-RegistryTargets')
        $targets = [ordered]@{}
        $targets['SqlUserName'] = ''
        $targets['SqlSecuredPassword'] = ''
        return $targets
    }
    function Set-RegistryTargets { param($KeyPath, $Targets) [void]$calls.Add('Set-RegistryTargets:' + (@($Targets.Keys) -join ',') + ":$script:Stage") }
    function Get-FileLength { param($Path) [void]$calls.Add("Get-FileLength:$(Split-Path -Leaf $Path)"); return [long]1234 }
    function Wait-VbrDbConnected {
        param($Psql, $Port, $Address, $Database, $SinceUtc, $TimeoutSec, $LogPath, $LogOffset, $PollSec, $ServiceName)
        [void]$calls.Add("Wait-VbrDbConnected:${LogOffset}:$TimeoutSec")
        return [pscustomobject]@{ Ok = [bool]$fake.ConnectOk; Detail = 'no new VBR backend within 600 seconds' }
    }
    function Clear-PostgresPassword { param($Psql, $Port, $Address, $Database) [void]$calls.Add("Clear-PostgresPassword:$script:Stage"); return [pscustomobject]@{ Ok = [bool]$fake.ClearOk; Detail = 'ALTER ROLE failed' } }
    function Get-OtherPasswordRoles { param($Psql, $Port, $Address, $Database) [void]$calls.Add('Get-OtherPasswordRoles'); return @($fake.OtherRoles) }
    function Restore-ConfFile { param($Path, $BackupPath, $ExpectedSddl) [void]$calls.Add("Restore-ConfFile:$(Split-Path -Leaf $Path):$ExpectedSddl") }
    function Restore-RegistrySnapshot {
        param($KeyPath, $Snapshot, $RegExportPath)
        [void]$calls.Add("Restore-RegistrySnapshot:$([IO.Path]::GetFileName("$RegExportPath"))")
        return [bool]$fake.RegRestoreOk
    }
    function Test-ServiceStaysRunning { param($Name, $Seconds) [void]$calls.Add("Test-ServiceStaysRunning:${Name}:$Seconds"); return [bool]$fake.SettleOk }
    function Read-LogTail { param($Path, $FromOffset) [void]$calls.Add("Read-LogTail:$FromOffset"); return @($fake.LogLines) }
    function Find-AuthErrors { param($Lines) return @($fake.AuthErrors) }
    function Write-LastFailure { param($WorkRoot, $RunDir, $Reason) [void]$calls.Add('Write-LastFailure'); $fake.LastFailureReason = $Reason }
}

# Happy path: every step in spec order, VERIFIED before the password is cleared.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'APPLY'
    foreach ($code in @('SVC_DISABLED', 'DB_NATIVE_AUTH', 'PG_HBA_NOT_STANDARD', 'PG_IDENT_NOT_STANDARD')) { $null = Add-RunIssue -Code $code -ExitCode 5 -Detail 'test' }
    $ctx = New-T17Ctx
    $result = Invoke-PathB -Ctx $ctx
    Check 'T17 happy: exit 0' $result.ExitCode 0
    Check 'T17 happy: no issue code' $result.Code ''
    Check 'T17 happy: spec order' ($calls -join ' > ') ('Test-LastFailure > Get-BusyVeeamWork > Get-VeeamServiceSnapshot > Get-ExternalDependents > ' +
        'New-RunFolder > Backup-ConfFile:pg_hba.conf > Backup-ConfFile:pg_ident.conf > Write-AtomicJson:services-before.json:VeeamBackupSvc,VeeamBrokerSvc > ' +
        'Get-RegistryValueSnapshot:SqlUserName,SqlSecuredPassword,PostgresUserForWindowsAuth,SqlHostName > ' +
        'Save-RegistryBackup:HKLM\SOFTWARE\Veeam\Veeam Backup and Replication\DatabaseConfigurations\PostgreSql > ' +
        'Write-ChangeMarker:B:PATH_B_CHANGING > Get-BusyVeeamWork > Stop-ServicesBounded:VeeamBackupSvc,VeeamBrokerSvc:PATH_B_CHANGING > ' +
        'Write-ConfFileAtomic:pg_ident.conf:PATH_B_CHANGING > Write-ConfFileAtomic:pg_hba.conf:PATH_B_CHANGING > ' +
        'Test-PgSspiLogin > Test-PgConfigHealth > Get-RegistryTargets > Set-RegistryTargets:SqlUserName,SqlSecuredPassword:PATH_B_CHANGING > ' +
        'Get-FileLength:Svc.VeeamBackup.log > Start-ServicesBounded:VeeamBackupSvc,VeeamBrokerSvc > Wait-VbrDbConnected:1234:600 > ' +
        'Remove-ChangeMarker > Clear-PostgresPassword:VERIFIED > Get-OtherPasswordRoles')
    Check 'T17 happy: stage VERIFIED' $script:Stage 'VERIFIED'
    Check 'T17 happy: Stopped recorded' ($ctx.Stopped -join ',') 'VeeamBackupSvc,VeeamBrokerSvc'
    Check 'T17 happy: StartUtc recorded' ($ctx.StartUtc -gt [DateTime]::MinValue) 'True'
    Check 'T17 happy: LogOffset recorded' $ctx.LogOffset 1234
    Check 'T17 happy: registry backup recorded' $ctx.RegBackup.RegPath (Join-Path $t16Root 'runs\20261012-101500\vbr-key.reg')
    Check 'T17 happy: PasswordCleared' $ctx.PasswordCleared 'True'
    Check 'T17 happy: only the account issue is left' ((@($script:Issues) | ForEach-Object { $_.Code }) -join ',') 'SVC_DISABLED'
    Check 'T17 happy: report DbAuth WINDOWS' $script:Report['DbAuth'] 'WINDOWS'
    Check 'T17 happy: report PgPassword NONE' $script:Report['PgPassword'] 'NONE'
    Check 'T17 happy: other password roles in Detail' ($result.Detail -like '*pg_native_admin*') 'True'
    Check 'T17 happy: no last-failure written' (@($calls | Where-Object { $_ -eq 'Write-LastFailure' }).Count) 0
}

# Step 1: last-failure.json blocks Path B before anything else.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    $fake.LastFailure = $true
    $result = Invoke-PathB -Ctx (New-T17Ctx)
    Check 'T17 previous failure: exit 5' $result.ExitCode 5
    Check 'T17 previous failure: code' $result.Code 'PATH_B_PREVIOUS_FAILURE'
    Check 'T17 previous failure: nothing else ran' ($calls -join ' > ') 'Test-LastFailure'
}

# Step 2: busy, and busy for longer than BusyPersistentHours.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    $busyQueue.Enqueue([pscustomobject]@{ Busy = $true; Persistent = $false; Names = @('VeeamAgent') })
    $result = Invoke-PathB -Ctx (New-T17Ctx)
    Check 'T17 busy: exit 10' $result.ExitCode 10
    Check 'T17 busy: code' $result.Code 'VEEAM_BUSY'
    Check 'T17 busy: names the process' ($result.Detail -like '*VeeamAgent*') 'True'
    Check 'T17 busy: no service snapshot' (@($calls | Where-Object { $_ -eq 'Get-VeeamServiceSnapshot' }).Count) 0
    $calls.Clear()
    $busyQueue.Enqueue([pscustomobject]@{ Busy = $true; Persistent = $true; Names = @('Veeam.Backup.Manager') })
    $result = Invoke-PathB -Ctx (New-T17Ctx)
    Check 'T17 persistent: exit 5' $result.ExitCode 5
    Check 'T17 persistent: code' $result.Code 'VEEAM_BUSY_PERSISTENT'
    Check 'T17 persistent: action' $result.Action 'Pause log backup or CDP jobs and re-run in a maintenance window'
}

# Step 3: a running service outside the stop set depends on a Veeam service.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    $fake.External = @('ThirdPartyMonitor')
    $result = Invoke-PathB -Ctx (New-T17Ctx)
    Check 'T17 external dependent: exit 5' $result.ExitCode 5
    Check 'T17 external dependent: code' $result.Code 'SERVICE_DEPENDENT_OUTSIDE_SET'
    Check 'T17 external dependent: named' ($result.Detail -like '*ThirdPartyMonitor*') 'True'
    Check 'T17 external dependent: no backup, no marker' (@($calls | Where-Object { $_ -like 'Backup-ConfFile*' -or $_ -like 'Write-ChangeMarker*' }).Count) 0
}

# Both texts are rendered before step 4: a name that cannot be written as ASCII stops
# Path B before any backup, marker or service stop, so there is no outage.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    function New-PgIdentText { param($Lines, $RequiredNames, $LineEnding, $Stamp) throw 'New-PgIdentText: the name is not printable ASCII' }
    Throws 'T17 render error reaches the trap' { Invoke-PathB -Ctx (New-T17Ctx) }
    Check 'T17 render error: no run folder, backup, marker or stop' (@($calls | Where-Object { $_ -like 'New-RunFolder*' -or $_ -like 'Backup-ConfFile*' -or $_ -like 'Write-ChangeMarker*' -or $_ -like 'Stop-ServicesBounded*' }).Count) 0
    Check 'T17 render error: stage stays UNTOUCHED' $script:Stage 'UNTOUCHED'
}

# Step 5: busy again after the marker: marker removed, nothing stopped.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    $busyQueue.Enqueue([pscustomobject]@{ Busy = $false; Persistent = $false; Names = @() })
    $busyQueue.Enqueue([pscustomobject]@{ Busy = $true; Persistent = $false; Names = @('VeeamAgent') })
    $result = Invoke-PathB -Ctx (New-T17Ctx)
    Check 'T17 busy at step 5: exit 10' $result.ExitCode 10
    Check 'T17 busy at step 5: marker removed' (@($calls)[-1]) 'Remove-ChangeMarker'
    Check 'T17 busy at step 5: nothing stopped' (@($calls | Where-Object { $_ -like 'Stop-ServicesBounded*' }).Count) 0
    Check 'T17 busy at step 5: stage back to UNTOUCHED' $script:Stage 'UNTOUCHED'
}

# Step 5: a service does not stop: start what was stopped, remove the marker, exit 10.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    $fake.NotStopped = @('VeeamBrokerSvc')
    $ctx = New-T17Ctx
    $result = Invoke-PathB -Ctx $ctx
    Check 'T17 wont stop: exit 10' $result.ExitCode 10
    Check 'T17 wont stop: code' $result.Code 'SERVICES_WONT_STOP'
    $afterStop = @($calls)[($calls.IndexOf('Stop-ServicesBounded:VeeamBackupSvc,VeeamBrokerSvc:PATH_B_CHANGING') + 1)..($calls.Count - 1)] -join ' > '
    Check 'T17 wont stop: starts only what it stopped, then removes the marker' $afterStop 'Start-ServicesBounded:VeeamBackupSvc > Remove-ChangeMarker'
    Check 'T17 wont stop: no file written' (@($calls | Where-Object { $_ -like 'Write-ConfFileAtomic*' }).Count) 0
    Check 'T17 wont stop: no last-failure' (@($calls | Where-Object { $_ -eq 'Write-LastFailure' }).Count) 0
    Check 'T17 wont stop: stage back to UNTOUCHED' $script:Stage 'UNTOUCHED'
    Check 'T17 wont stop: Stopped is what stopped' ($ctx.Stopped -join ',') 'VeeamBackupSvc'
}

# Step 5: a service does not stop and a stopped one does not start again -> 50, marker stays.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    $fake.NotStopped = @('VeeamBrokerSvc')
    $startQueue.Enqueue($false)
    $result = Invoke-PathB -Ctx (New-T17Ctx)
    Check 'T17 wont stop, wont start: exit 50' $result.ExitCode 50
    Check 'T17 wont stop, wont start: code' $result.Code 'ROLLBACK_FAILED'
    Check 'T17 wont stop, wont start: marker stays' (@($calls | Where-Object { $_ -eq 'Remove-ChangeMarker' }).Count) 0
}

# Step 7: SSPI test fails -> rollback before any registry change -> 40.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    $sspiQueue.Enqueue($false)
    $result = Invoke-PathB -Ctx (New-T17Ctx)
    Check 'T17 SSPI fails: exit 40' $result.ExitCode 40
    Check 'T17 SSPI fails: code' $result.Code 'PG_SSPI_TEST_FAILED'
    Check 'T17 SSPI fails: registry never changed' (@($calls | Where-Object { $_ -like 'Set-RegistryTargets*' }).Count) 0
    Check 'T17 SSPI fails: password never cleared' (@($calls | Where-Object { $_ -like 'Clear-PostgresPassword*' }).Count) 0
    $afterTest = @($calls)[($calls.IndexOf('Test-PgSspiLogin') + 1)..($calls.Count - 1)] -join ' > '
    Check 'T17 SSPI fails: rollback order' $afterTest ('Stop-ServicesBounded:VeeamBackupSvc,VeeamBrokerSvc:PATH_B_CHANGING > ' +
        'Restore-ConfFile:pg_ident.conf:SDDL-IDENT > Restore-ConfFile:pg_hba.conf:SDDL-HBA > Restore-RegistrySnapshot:vbr-key.reg > ' +
        'Get-FileLength:Svc.VeeamBackup.log > Start-ServicesBounded:VeeamBackupSvc,VeeamBrokerSvc > Test-ServiceStaysRunning:VeeamBackupSvc:300 > ' +
        'Read-LogTail:1234 > Write-LastFailure > Remove-ChangeMarker')
    Check 'T17 SSPI fails: last-failure names the reason' ($fake.LastFailureReason -like 'PG_SSPI_TEST_FAILED:*') 'True'
}

# Step 10: VBR does not connect -> rollback -> 40; the password is never cleared.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    $fake.ConnectOk = $false
    $result = Invoke-PathB -Ctx (New-T17Ctx)
    Check 'T17 connect fails: exit 40' $result.ExitCode 40
    Check 'T17 connect fails: code' $result.Code 'VBR_DB_CONNECT_FAILED'
    Check 'T17 connect fails: registry was switched first' (@($calls | Where-Object { $_ -like 'Set-RegistryTargets*' }).Count) 1
    Check 'T17 connect fails: password never cleared' (@($calls | Where-Object { $_ -like 'Clear-PostgresPassword*' }).Count) 0
    Check 'T17 connect fails: last-failure written' (@($calls | Where-Object { $_ -eq 'Write-LastFailure' }).Count) 1
    Check 'T17 connect fails: never VERIFIED' $script:Stage 'PATH_B_CHANGING'
}

# Step 10 fails and the rollback cannot prove VBR works -> 50, marker stays.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    $fake.ConnectOk = $false
    $fake.SettleOk = $false
    $result = Invoke-PathB -Ctx (New-T17Ctx)
    Check 'T17 rollback fails: exit 50' $result.ExitCode 50
    Check 'T17 rollback fails: code' $result.Code 'ROLLBACK_FAILED'
    Check 'T17 rollback fails: detail keeps the cause' ($result.Detail -like 'VBR_DB_CONNECT_FAILED:*') 'True'
    Check 'T17 rollback fails: marker stays' (@($calls | Where-Object { $_ -eq 'Remove-ChangeMarker' }).Count) 0
    Check 'T17 rollback fails: last-failure still written' (@($calls | Where-Object { $_ -eq 'Write-LastFailure' }).Count) 1
}

# Step 6: an unexpected write error -> rollback here -> 40 UNHANDLED_ERROR.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    $fake.WriteThrows = 'The process cannot access the file'
    $result = Invoke-PathB -Ctx (New-T17Ctx)
    Check 'T17 write error: exit 40' $result.ExitCode 40
    Check 'T17 write error: code' $result.Code 'UNHANDLED_ERROR'
    Check 'T17 write error: rollback restored the files' (@($calls | Where-Object { $_ -like 'Restore-ConfFile*' }).Count) 2
}

# Step 12: the password cannot be cleared after VERIFIED -> 5, no rollback.
& {
    . $t17Mocks
    $script:Stage = 'UNTOUCHED'
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'APPLY'
    $fake.ClearOk = $false
    $ctx = New-T17Ctx
    $result = Invoke-PathB -Ctx $ctx
    Check 'T17 password not cleared: exit 5' $result.ExitCode 5
    Check 'T17 password not cleared: code' $result.Code 'PG_PASSWORD_NOT_CLEARED'
    Check 'T17 password not cleared: stage VERIFIED' $script:Stage 'VERIFIED'
    Check 'T17 password not cleared: no rollback' (@($calls | Where-Object { $_ -like 'Restore-*' -or $_ -eq 'Write-LastFailure' }).Count) 0
    Check 'T17 password not cleared: marker removed before the password step' ($calls.IndexOf('Remove-ChangeMarker') -lt $calls.IndexOf('Clear-PostgresPassword:VERIFIED')) 'True'
    Check 'T17 password not cleared: step 13 still ran' (@($calls)[-1]) 'Get-OtherPasswordRoles'
}

# Invoke-PathBRollback on its own: order and the 40 rule.
& {
    . $t17Mocks
    $script:Stage = 'PATH_B_CHANGING'
    $ctx = New-T17Ctx
    $ctx.StopSet = @('VeeamBackupSvc', 'VeeamBrokerSvc')
    $ctx.RunDir = 'C:\runs\20261012-101500'
    $ctx.HbaBackupPath = 'C:\runs\20261012-101500\pg_hba.conf.before'
    $ctx.IdentBackupPath = 'C:\runs\20261012-101500\pg_ident.conf.before'
    $ctx.RegSnapshot = @{ SqlUserName = [pscustomobject]@{ Exists = $true; Kind = 'String'; Data = 'postgres' } }
    $ctx.RegBackup = [pscustomobject]@{ JsonPath = 'C:\runs\20261012-101500\registry-before.json'; RegPath = 'C:\runs\20261012-101500\vbr-key.reg' }
    $result = Invoke-PathBRollback -Ctx $ctx -Reason 'VBR_DB_CONNECT_FAILED: no new VBR backend'
    Check 'T17 rollback: exit 40' $result.ExitCode 40
    Check 'T17 rollback: code from the reason' $result.Code 'VBR_DB_CONNECT_FAILED'
    Check 'T17 rollback: files, then registry, then services, then checks' ($calls -join ' > ') ('Stop-ServicesBounded:VeeamBackupSvc,VeeamBrokerSvc:PATH_B_CHANGING > ' +
        'Restore-ConfFile:pg_ident.conf:SDDL-IDENT > Restore-ConfFile:pg_hba.conf:SDDL-HBA > Restore-RegistrySnapshot:vbr-key.reg > ' +
        'Get-FileLength:Svc.VeeamBackup.log > Start-ServicesBounded:VeeamBackupSvc,VeeamBrokerSvc > Test-ServiceStaysRunning:VeeamBackupSvc:300 > ' +
        'Read-LogTail:1234 > Write-LastFailure > Remove-ChangeMarker')
    Check 'T17 rollback: detail has no doubled code' ($result.Detail -like 'no new VBR backend*') 'True'

    $calls.Clear()
    $result = Invoke-PathBRollback -Ctx $ctx -Reason 'something odd'
    Check 'T17 rollback: reason without a code -> UNHANDLED_ERROR' $result.Code 'UNHANDLED_ERROR'

    $calls.Clear()
    $fake.NotStopped = @('VeeamBrokerSvc')
    $result = Invoke-PathBRollback -Ctx $ctx -Reason 'VBR_DB_CONNECT_FAILED: x'
    Check 'T17 rollback: a service will not stop -> 50' "$($result.ExitCode) $($result.Code)" '50 ROLLBACK_FAILED'
    Check 'T17 rollback: still restores files and registry and starts services' (@($calls | Where-Object { $_ -like 'Restore-*' -or $_ -like 'Start-ServicesBounded*' }).Count) 4
    Check 'T17 rollback: no settle wait after a failure' (@($calls | Where-Object { $_ -like 'Test-ServiceStaysRunning*' }).Count) 0
    Check 'T17 rollback: 50 keeps the marker' (@($calls | Where-Object { $_ -eq 'Remove-ChangeMarker' }).Count) 0
    Check 'T17 rollback: 50 still writes last-failure' (@($calls | Where-Object { $_ -eq 'Write-LastFailure' }).Count) 1

    $calls.Clear()
    $fake.NotStopped = @()
    $fake.RegRestoreOk = $false
    $result = Invoke-PathBRollback -Ctx $ctx -Reason 'VBR_DB_CONNECT_FAILED: x'
    Check 'T17 rollback: registry mismatch -> 50' $result.ExitCode 50

    $calls.Clear()
    $fake.RegRestoreOk = $true
    $fake.LogLines = @('2026-10-12 FATAL: SSPI authentication failed for user "postgres"')
    $fake.AuthErrors = @('2026-10-12 FATAL: SSPI authentication failed for user "postgres"')
    $result = Invoke-PathBRollback -Ctx $ctx -Reason 'VBR_DB_CONNECT_FAILED: x'
    Check 'T17 rollback: new auth error in the VBR log -> 50' $result.ExitCode 50
    Check 'T17 rollback: auth error named in Detail' ($result.Detail -like '*SSPI authentication failed*') 'True'
}
$script:Stage = 'UNTOUCHED'
$script:Issues = New-Object System.Collections.ArrayList
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: every check up to Task 16 prints `PASS`. Each Task 17 block prints one line `  FAIL  UNHANDLED  The term 'Invoke-PathB' is not recognized as the name of a cmdlet, function, script file, or operable program.` followed by the PowerShell spelling hint (twelve blocks), and the last block prints the same line for `Invoke-PathBRollback`. The `T17 render error` block prints no such line: its call sits inside `Throws`, and its three checks pass without the code. The run ends with `RESULT: <n> passed, 13 failed`, where `<n>` is the Task 16 total plus 3 (`RESULT: 1229 passed, 13 failed` on an elevated prompt on English Windows without PostgreSQL or VBR), and exit code 1.

- [ ] **Step 3: Implement**

Insert this code just above the line `#endregion PathB` in `Invoke-VbrStandardise.ps1`:

```powershell
# Spec 7.6 Path B rollback. Runs every step even when an earlier one fails, and
# never throws. Reason starts with the issue code of the failure that caused the
# rollback, for example 'VBR_DB_CONNECT_FAILED: no new VBR backend'. Returns
# { ExitCode; Code; Detail; Action }:
#   40 with that code (UNHANDLED_ERROR when Reason has no code) when the files and
#      registry are back, the services run, VeeamBackupSvc stays running for
#      RollbackSettleSec and Svc.VeeamBackup.log shows no new authentication error;
#   50 ROLLBACK_FAILED otherwise. The marker stays on 50.
# last-failure.json is written in both cases, so a scheduled -Apply does not cause
# the same outage again.
function Invoke-PathBRollback {
    param(
        [Parameter(Mandatory)][hashtable] $Ctx,
        [Parameter(Mandatory)][string] $Reason
    )
    $cfg = $Ctx.Config
    $vbrLog = 'C:\ProgramData\Veeam\Backup\Svc.VeeamBackup.log'
    $timeoutSec = [int]$cfg.ServiceStopTimeoutSec
    $problems = New-Object System.Collections.ArrayList
    $stopSet = @($Ctx['StopSet'] | Where-Object { $_ })
    $reasonCode = 'UNHANDLED_ERROR'
    if ($Reason -match '^([A-Z][A-Z0-9_]+):') { $reasonCode = $Matches[1] }
    $reasonText = $Reason -replace '^[A-Z][A-Z0-9_]+:\s*', ''
    Write-Log "PATH B ROLLBACK: $Reason" -Level ERROR

    Write-Log 'Rollback step 1 - stop the Veeam services' -Level STEP
    if ($stopSet.Count -gt 0) {
        try {
            $stop = Stop-ServicesBounded -Names $stopSet -TimeoutSec $timeoutSec
            if (-not $stop.Ok) { [void]$problems.Add('service(s) did not stop: ' + (@($stop.NotStopped) -join ', ')) }
        } catch {
            [void]$problems.Add("stopping the services failed: $($_.Exception.Message)")
        }
    }

    Write-Log 'Rollback step 2 - restore pg_ident.conf and pg_hba.conf from the run folder' -Level STEP
    $files = @(
        @{ Name = 'pg_ident.conf'; Live = "$($Ctx.Pg.IdentPath)"; Backup = "$($Ctx['IdentBackupPath'])"; Sddl = "$($Ctx.Ident.Sddl)" },
        @{ Name = 'pg_hba.conf';   Live = "$($Ctx.Pg.HbaPath)";   Backup = "$($Ctx['HbaBackupPath'])";   Sddl = "$($Ctx.Hba.Sddl)" }
    )
    foreach ($file in $files) {
        try {
            if ([string]::IsNullOrEmpty($file.Backup)) { throw "no backup of $($file.Name) is recorded" }
            $null = Restore-ConfFile -Path $file.Live -BackupPath $file.Backup -ExpectedSddl $file.Sddl
            Write-Log "Restored $($file.Name) from $($file.Backup)" -Level OK
        } catch {
            [void]$problems.Add("restoring $($file.Name) failed: $($_.Exception.Message)")
        }
    }

    Write-Log 'Rollback step 3 - restore the registry values from registry-before.json' -Level STEP
    try {
        $snapshot = $Ctx['RegSnapshot']
        if ($snapshot -isnot [hashtable]) { throw 'no registry snapshot is recorded' }
        $restoreArgs = @{ KeyPath = "$($Ctx.Db.KeyPath)"; Snapshot = $snapshot }
        if ($null -ne $Ctx['RegBackup']) {
            $regExport = "$(Get-CfgValue -Object $Ctx['RegBackup'] -Name 'RegPath' -Default '')"
            if ($regExport) { $restoreArgs['RegExportPath'] = $regExport }
        }
        if (-not (Restore-RegistrySnapshot @restoreArgs)) {
            [void]$problems.Add('the registry values still differ from registry-before.json after the restore and the reg.exe import')
        }
    } catch {
        [void]$problems.Add("restoring the registry failed: $($_.Exception.Message)")
    }

    Write-Log 'Rollback step 4 - start the services that were running before' -Level STEP
    $logOffset = [long]0
    try { $logOffset = [long](Get-FileLength -Path $vbrLog) } catch { $logOffset = [long]0 }
    if ($stopSet.Count -gt 0) {
        try {
            $order = @(Get-StartOrder -Snapshot @($Ctx['Snapshot']) -Names $stopSet)
            $start = Start-ServicesBounded -Names $order -TimeoutSec $timeoutSec
            if (-not $start.Ok) { [void]$problems.Add('service(s) did not start: ' + (@($start.NotStarted) -join ', ')) }
        } catch {
            [void]$problems.Add("starting the services failed: $($_.Exception.Message)")
        }
    }

    Write-Log 'Rollback step 5 - check that VBR works again' -Level STEP
    if ($problems.Count -eq 0) {
        try {
            $settleSec = [int]$cfg.RollbackSettleSec
            if (-not (Test-ServiceStaysRunning -Name 'VeeamBackupSvc' -Seconds $settleSec)) {
                [void]$problems.Add("VeeamBackupSvc did not stay running for $settleSec seconds")
            }
            $newLines = @(Read-LogTail -Path $vbrLog -FromOffset $logOffset)
            if ($newLines.Count -gt 0) {
                $authErrors = @(Find-AuthErrors -Lines $newLines)
                if ($authErrors.Count -gt 0) {
                    [void]$problems.Add('new authentication errors in Svc.VeeamBackup.log: ' + (Format-ShortText -Text ($authErrors -join ' | ') -MaxLength 300))
                }
            }
        } catch {
            [void]$problems.Add("the check after the rollback failed: $($_.Exception.Message)")
        }
    } else {
        Write-Log 'Skipping the settle check, because the rollback already failed.' -Level WARN
    }

    Write-Log 'Rollback step 6 - write last-failure.json' -Level STEP
    $exitCode = 40
    if ($problems.Count -gt 0) { $exitCode = 50 }
    $summary = 'rollback complete: pg_ident.conf, pg_hba.conf and the registry were restored, the Veeam services run and VeeamBackupSvc stayed up with no new authentication error.'
    if ($exitCode -eq 50) { $summary = 'ROLLBACK FAILED: ' + ($problems -join '; ') + '.' }
    $notes = ''
    try {
        $null = Write-LastFailure -WorkRoot $Ctx.WorkRoot -RunDir "$($Ctx['RunDir'])" -Reason "$Reason | $summary"
    } catch {
        $notes += " last-failure.json could not be written ($($_.Exception.Message)), so a scheduled -Apply can repeat this outage."
    }
    if ($exitCode -eq 40) {
        if (-not (Remove-ChangeMarker -WorkRoot $Ctx.WorkRoot)) {
            $notes += " The marker could not be removed: delete $(Join-Path $Ctx.WorkRoot 'CHANGES-IN-PROGRESS.marker') after checking."
        }
        Write-Log $summary -Level WARN
        return [pscustomobject]@{
            ExitCode = 40
            Code     = $reasonCode
            Detail   = "$reasonText; $summary Run folder: $($Ctx['RunDir']).$notes"
            Action   = "PAGE AN OPERATOR. VBR works again on its old settings. Read the run folder named in $(Join-Path $Ctx.WorkRoot 'last-failure.json'), fix the cause, delete that file, then re-run with -Apply in a maintenance window."
        }
    }
    Write-Log $summary -Level ERROR
    return [pscustomobject]@{
        ExitCode = 50
        Code     = 'ROLLBACK_FAILED'
        Detail   = "$Reason; $summary The marker stays. Run folder: $($Ctx['RunDir']).$notes"
        Action   = 'PAGE AN OPERATOR NOW. VBR may be down. Follow the MARKER_PRESENT recovery steps in README.md with the run folder in Detail.'
    }
}

# Spec 7.6 Path B: full conversion to Windows authentication, with a short outage.
# Returns { ExitCode; Code; Detail; Action } (Code '' means success). Every failure
# from the first service stop to the VBR connect check runs Invoke-PathBRollback
# here. An unexpected error after the marker but outside that block reaches the
# trap, which runs the same rollback because the stage is PATH_B_CHANGING.
function Invoke-PathB {
    param([Parameter(Mandatory)][hashtable] $Ctx)
    $cfg = $Ctx.Config
    $state = $Ctx['State']
    $timeoutSec = [int]$cfg.ServiceStopTimeoutSec
    $psql = "$($Ctx.Pg.Psql)"
    $port = [int]$Ctx.Pg.Port
    $addresses = @($Ctx.Addresses)
    $database = "$($Ctx.Db.DatabaseName)"
    $vbrLog = 'C:\ProgramData\Veeam\Backup\Svc.VeeamBackup.log'
    $notes = New-Object System.Collections.ArrayList

    # Spec 7.11 idle gate. Returns a result object when the server is busy, else $null.
    $idleGate = {
        $processes = @(Get-Process -Name 'Veeam*' -ErrorAction SilentlyContinue | ForEach-Object {
            $proc = $_
            $started = $null
            try { $started = $proc.StartTime } catch { $started = $null }
            if ($null -eq $started) { $started = Get-Date }
            [pscustomobject]@{ Name = "$($proc.ProcessName)"; StartTime = $started }
        })
        $busy = Get-BusyVeeamWork -Processes $processes -Now (Get-Date) -PersistentHours ([int]$cfg.BusyPersistentHours)
        $names = (@($busy.Names) -join ', ')
        if ($busy.Persistent) {
            return [pscustomobject]@{
                ExitCode = 5
                Code     = 'VEEAM_BUSY_PERSISTENT'
                Detail   = "Veeam work has run for more than $($cfg.BusyPersistentHours) hours: $names"
                Action   = 'Pause log backup or CDP jobs and re-run in a maintenance window'
            }
        }
        if ($busy.Busy) {
            return [pscustomobject]@{ ExitCode = 10; Code = 'VEEAM_BUSY'; Detail = "Veeam work is running: $names"; Action = '' }
        }
        return $null
    }

    Write-Log 'Path B step 1 - check for an earlier failed conversion' -Level STEP
    if (Test-LastFailure -WorkRoot $Ctx.WorkRoot) {
        return [pscustomobject]@{
            ExitCode = 5
            Code     = 'PATH_B_PREVIOUS_FAILURE'
            Detail   = "An earlier Path B run failed and was rolled back: $(Join-Path $Ctx.WorkRoot 'last-failure.json')"
            Action   = 'Read the run folder named in last-failure.json, fix the cause, delete last-failure.json, then re-run with -Apply'
        }
    }

    Write-Log 'Path B step 2 - idle gate' -Level STEP
    $gate = & $idleGate
    if ($null -ne $gate) { return $gate }

    Write-Log 'Path B step 3 - record the Veeam services and find the stop set' -Level STEP
    $Ctx['Snapshot'] = @(Get-VeeamServiceSnapshot)
    $Ctx['StopSet'] = @(Get-StopSet -Snapshot $Ctx['Snapshot'])
    $Ctx['Stopped'] = @()
    $external = @()
    if ($Ctx['StopSet'].Count -gt 0) {
        $allServices = @(Get-Service -ErrorAction SilentlyContinue | ForEach-Object {
            $svc = $_
            $dependsOn = @()
            try { $dependsOn = @($svc.ServicesDependedOn | ForEach-Object { $_.Name }) } catch { $dependsOn = @() }
            [pscustomobject]@{ Name = "$($svc.Name)"; Status = "$($svc.Status)"; DependsOn = $dependsOn }
        })
        $external = @(Get-ExternalDependents -StopSet $Ctx['StopSet'] -AllServices $allServices)
    }
    if ($external.Count -gt 0) {
        return [pscustomobject]@{
            ExitCode = 5
            Code     = 'SERVICE_DEPENDENT_OUTSIDE_SET'
            Detail   = 'Running service(s) outside the Veeam stop set depend on a Veeam service: ' + ($external -join ', ')
            Action   = 'Stop or reconfigure the dependent service(s) named in Detail, then re-run with -Apply'
        }
    }
    Write-Log ('Stop set: ' + ($Ctx['StopSet'] -join ', '))

    # Render both new texts before any backup, marker or service stop (Task 10): a name
    # that cannot be written as ASCII then stops the run here, at stage UNTOUCHED, with
    # nothing changed and no outage.
    $identText = ''
    $hbaText = ''
    if ("$($state['PgIdent'])" -ne 'STANDARD') { $identText = New-PgIdentText -Lines @($Ctx.IdentLines) -RequiredNames @($Ctx.RequiredIdentNames) -LineEnding $Ctx.Ident.LineEnding -Stamp $Ctx.Stamp }
    if ("$($state['PgHba'])" -ne 'STANDARD') { $hbaText = New-PgHbaText -Lines @($Ctx.HbaLines) -LineEnding $Ctx.Hba.LineEnding -Stamp $Ctx.Stamp }

    Write-Log 'Path B step 4 - back up the config files and the registry, then write the marker' -Level STEP
    $Ctx['RunDir'] = New-RunFolder -WorkRoot $Ctx.WorkRoot -Stamp $Ctx.Stamp
    $Ctx['HbaBackupPath'] = Backup-ConfFile -Path $Ctx.Pg.HbaPath -RunDir $Ctx.RunDir
    $Ctx['IdentBackupPath'] = Backup-ConfFile -Path $Ctx.Pg.IdentPath -RunDir $Ctx.RunDir
    Write-Log "pg_hba.conf SDDL before the change: $($Ctx.Hba.Sddl)"
    Write-Log "pg_ident.conf SDDL before the change: $($Ctx.Ident.Sddl)"
    # For a person who recovers by hand (README, MARKER_PRESENT): which services ran.
    $null = Write-AtomicJson -Path (Join-Path $Ctx.RunDir 'services-before.json') -Object ([ordered]@{ StopSet = @($Ctx['StopSet']); Services = @($Ctx['Snapshot']) })
    $Ctx['RegSnapshot'] = Get-RegistryValueSnapshot -KeyPath $Ctx.Db.KeyPath -Names @('SqlUserName', 'SqlSecuredPassword', 'PostgresUserForWindowsAuth', 'SqlHostName')
    $Ctx['RegBackup'] = Save-RegistryBackup -KeyPath $Ctx.Db.KeyPath -ExportKeyPath (ConvertTo-RegExePath -KeyPath $Ctx.Db.KeyPath) -RunDir $Ctx.RunDir -Snapshot $Ctx['RegSnapshot']
    $null = Write-ChangeMarker -WorkRoot $Ctx.WorkRoot -RunDir $Ctx.RunDir -PathName 'B' -Stage 'PATH_B_CHANGING'
    $script:Stage = 'PATH_B_CHANGING'

    Write-Log 'Path B step 5 - idle gate again, then stop the stop set' -Level STEP
    $gate = & $idleGate
    if ($null -ne $gate) {
        $null = Remove-ChangeMarker -WorkRoot $Ctx.WorkRoot
        $script:Stage = 'UNTOUCHED'
        return $gate
    }
    if ($Ctx['StopSet'].Count -gt 0) {
        $stop = Stop-ServicesBounded -Names $Ctx['StopSet'] -TimeoutSec $timeoutSec
        $Ctx['Stopped'] = @($stop.Stopped | Where-Object { $_ })
        if (-not $stop.Ok) {
            $notStopped = (@($stop.NotStopped) -join ', ')
            Write-Log "Service(s) did not stop: $notStopped. Starting what this run stopped." -Level ERROR
            if ($Ctx['Stopped'].Count -gt 0) {
                $restart = Start-ServicesBounded -Names @(Get-StartOrder -Snapshot $Ctx['Snapshot'] -Names $Ctx['Stopped']) -TimeoutSec $timeoutSec
                if (-not $restart.Ok) {
                    return [pscustomobject]@{
                        ExitCode = 50
                        Code     = 'ROLLBACK_FAILED'
                        Detail   = "SERVICES_WONT_STOP: $notStopped did not stop, and $(@($restart.NotStarted) -join ', ') did not start again. No file or registry value was changed. The marker stays."
                        Action   = 'PAGE AN OPERATOR NOW. Start the stopped Veeam services, then delete the marker.'
                    }
                }
            }
            $null = Remove-ChangeMarker -WorkRoot $Ctx.WorkRoot
            $script:Stage = 'UNTOUCHED'
            return [pscustomobject]@{
                ExitCode = 10
                Code     = 'SERVICES_WONT_STOP'
                Detail   = "$notStopped did not stop within $timeoutSec seconds. The services this run stopped were started again; nothing else was changed."
                Action   = ''
            }
        }
    }

    $failReason = ''
    try {
        Write-Log 'Path B step 6 - write pg_ident.conf, then pg_hba.conf' -Level STEP
        if ("$($state['PgIdent'])" -ne 'STANDARD') {
            $null = Write-ConfFileAtomic -Path $Ctx.Pg.IdentPath -Bytes (ConvertTo-Latin1Bytes -Text $identText) -ExpectedSddl $Ctx.Ident.Sddl
            Write-Log "Wrote $($Ctx.Pg.IdentPath)" -Level OK
        }
        if ("$($state['PgHba'])" -ne 'STANDARD') {
            $hbaRules = @($Ctx.HbaRules | Where-Object { $null -ne $_ })
            if ($hbaRules.Count -gt 0) {
                foreach ($rule in @(Get-NonLoopbackHbaRules -Rules $hbaRules)) {
                    $ruleText = "line $([int]$rule.LineIndex + 1): $($rule.Type) $($rule.Database) $($rule.User) $($rule.Address) $($rule.Method)"
                    Write-Log "pg_hba.conf line for another address is commented out: $ruleText" -Level WARN
                    [void]$notes.Add("Commented out pg_hba.conf $ruleText.")
                }
            }
            $null = Write-ConfFileAtomic -Path $Ctx.Pg.HbaPath -Bytes (ConvertTo-Latin1Bytes -Text $hbaText) -ExpectedSddl $Ctx.Hba.Sddl
            Write-Log "Wrote $($Ctx.Pg.HbaPath)" -Level OK
        }

        Write-Log 'Path B step 7 - SSPI test as SYSTEM and PostgreSQL config check' -Level STEP
        $sspi = Test-PgSspiLogin -Psql $psql -Port $port -Addresses $addresses -Database $database
        if (-not $sspi.Passed) {
            $failed = @($sspi.Results | Where-Object { $null -ne $_ -and "$($_.Kind)" -ne 'OK' } | ForEach-Object { "$($_.Address) $($_.Kind) $($_.StdErr)" })
            $failReason = 'PG_SSPI_TEST_FAILED: SSPI login as SYSTEM failed after the write: ' + ($failed -join '; ')
        } else {
            $health = Test-PgConfigHealth -Psql $psql -Port $port -Address $addresses[0] -Database $database -Major ([int]$Ctx.Pg.Major) -HbaPath "$($Ctx.Pg.HbaPath)" -IdentPath "$($Ctx.Pg.IdentPath)"
            if (-not $health.Ok) { $failReason = "PG_SSPI_TEST_FAILED: PostgreSQL reports a problem with the new files: $($health.Detail)" }
        }

        if (-not $failReason) {
            Write-Log 'Path B step 8 - switch the VBR registry values to Windows authentication' -Level STEP
            $targets = Get-RegistryTargets -DbConfig $Ctx.Db -Addresses $addresses
            $null = Set-RegistryTargets -KeyPath $Ctx.Db.KeyPath -Targets $targets
            Write-Log ('Registry values set: ' + (@($targets.Keys) -join ', ')) -Level OK

            Write-Log 'Path B step 9 - start the services that were running' -Level STEP
            $Ctx['StartUtc'] = [DateTime]::UtcNow
            $Ctx['LogOffset'] = [long](Get-FileLength -Path $vbrLog)
            if ($Ctx['StopSet'].Count -gt 0) {
                $start = Start-ServicesBounded -Names @(Get-StartOrder -Snapshot $Ctx['Snapshot'] -Names $Ctx['StopSet']) -TimeoutSec $timeoutSec
                if (-not $start.Ok) {
                    $failReason = 'VBR_DB_CONNECT_FAILED: service(s) did not start after the switch: ' + (@($start.NotStarted) -join ', ')
                }
            }
        }

        if (-not $failReason) {
            Write-Log 'Path B step 10 - wait until VBR connects to its database' -Level STEP
            $wait = Wait-VbrDbConnected -Psql $psql -Port $port -Address $addresses[0] -Database $database -SinceUtc $Ctx['StartUtc'] -TimeoutSec ([int]$cfg.VbrConnectTimeoutSec) -LogPath $vbrLog -LogOffset ([long]$Ctx['LogOffset'])
            if (-not $wait.Ok) { $failReason = "VBR_DB_CONNECT_FAILED: $($wait.Detail)" }
        }
    } catch {
        $failReason = "UNHANDLED_ERROR: $($_.Exception.Message)"
    }
    if ($failReason) {
        Write-Log $failReason -Level ERROR
        return (Invoke-PathBRollback -Ctx $Ctx -Reason $failReason)
    }

    Write-Log 'Path B step 11 - VBR works with Windows authentication; from here on there is no rollback' -Level STEP
    $script:Stage = 'VERIFIED'
    $markerRemoved = $false
    try { $markerRemoved = [bool](Remove-ChangeMarker -WorkRoot $Ctx.WorkRoot) } catch { $markerRemoved = $false }
    if (-not $markerRemoved) {
        $null = Add-RunIssue -Code 'POST_CONVERSION_STEP_FAILED' -ExitCode 5 -Detail "VBR works with Windows authentication, but the marker could not be removed: $(Join-Path $Ctx.WorkRoot 'CHANGES-IN-PROGRESS.marker')" -Action 'Delete the marker file named in Detail, then re-run'
    }
    Clear-PathFixedIssues -Ctx $Ctx
    [void]$notes.Add("VBR now uses Windows authentication. Backups: $($Ctx['RunDir']).")

    $passwordFailure = ''
    try {
        Write-Log 'Path B step 12 - clear the postgres password' -Level STEP
        $clear = Clear-PostgresPassword -Psql $psql -Port $port -Address $addresses[0] -Database $database
        if ($clear.Ok) {
            $Ctx['PasswordCleared'] = $true
            Write-Log 'The postgres password is cleared.' -Level OK
        } else {
            $passwordFailure = "$($clear.Detail)"
        }
        Clear-PathFixedIssues -Ctx $Ctx -IncludePassword

        Write-Log 'Path B step 13 - list other roles that log in with a password' -Level STEP
        $otherRoles = @(Get-OtherPasswordRoles -Psql $psql -Port $port -Address $addresses[0] -Database $database | Where-Object { $_ })
        if ($otherRoles.Count -gt 0) {
            Write-Log ('Roles with LOGIN and a password, which can no longer log in: ' + ($otherRoles -join ', ')) -Level WARN
            [void]$notes.Add('Roles with LOGIN and a password that can no longer log in: ' + ($otherRoles -join ', ') + '.')
        }
    } catch {
        return [pscustomobject]@{
            ExitCode = 5
            Code     = 'POST_CONVERSION_STEP_FAILED'
            Detail   = "VBR works with Windows authentication, but a step after the switch failed: $($_.Exception.Message) $($notes -join ' ')"
            Action   = 'Re-run with -Apply to finish the remaining steps'
        }
    }

    if ($passwordFailure) {
        return [pscustomobject]@{
            ExitCode = 5
            Code     = 'PG_PASSWORD_NOT_CLEARED'
            Detail   = "VBR works with Windows authentication, but the postgres password could not be cleared: $passwordFailure $($notes -join ' ')"
            Action   = 'Re-run with -Apply to clear the postgres password'
        }
    }
    return [pscustomobject]@{ ExitCode = 0; Code = ''; Detail = ($notes -join ' '); Action = '' }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: <n> passed, 0 failed`, where `<n>` is the total after Task 16 plus 84 (`RESULT: 1310 passed, 0 failed` on an elevated prompt on English Windows without PostgreSQL or VBR). Exit code 0.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add Path B conversion with bounded stop, verify and rollback" -m "Path B backs up the files, registry values and service state before the marker, stops the Veeam services with a bound, writes the files, tests SSPI, switches the registry, starts the services and waits for a new VBR backend. Any failure before VERIFIED rolls back files, then registry, then services, and returns 40 only when VeeamBackupSvc stays up with no new auth error; otherwise 50. Every rollback writes last-failure.json. The postgres password is cleared only after VERIFIED." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 18: Main body, audit, trap and policy tests

**Files:**
- Modify: `Invoke-VbrStandardise.ps1` (region MainHelpers, and everything below the MAIN line)
- Modify: `Test-VbrStandardise.ps1`

**Interfaces:**
- Consumes: `Get-DefaultConfig`, `Get-ExitCodeTable`, `Write-Log`, `Format-ShortText`, `Get-RegValue` (tests), `Get-CfgValue` (Task 1); `New-RunReport`, `Add-RunIssue`, `Get-TrapAction`, `Complete-Run` (Task 2); `Test-IsAdministrator`, `Get-PreflightContextIssue`, `Enter-RunLock`, `Find-ChangeMarkers`, `Test-IsDomainController`, `Initialize-WorkRoot`, `Remove-ChangeMarker`, `Test-LastFailure`, `Remove-OldRunData` (Task 3); `Get-VbrInstall`, `Test-Vb365Installed`, `Get-VbrDbConfig`, `Get-EnterpriseManagerDbConfig`, `Get-LocalHostNames`, `Get-DbHostClass`, `Get-RegistryAuthMode` (Task 4); `Find-PgInstall`, `Test-PostmasterLive`, `Test-PgConfOverride`, `Get-ListeningLoopback` (Task 5); `ConvertTo-SspiMapName`, `Get-SystemMapNames`, `Get-VeeamServiceAccountNames` (Task 6); `Invoke-ServiceAccountStep` (Task 7); `Read-ConfFile`, `Split-ConfLines` (Task 8); `Get-PgHbaRules`, `Test-PgHbaHasInclude`, `Test-PgHbaStandard`, `Get-NonLoopbackHbaRules`, `Get-HbaFirstMatch` (Task 9); `Get-PgIdentEntries`, `Get-RequiredIdentNames`, `Get-PgIdentStatus` (Task 10); `Test-PgSspiLogin`, `Test-PgConfigHealth`, `Get-PgLiveState` (Task 11); `Test-VbrBackendsOk`, `Get-DbAuthState`, `Get-EstablishedRemoteClients`, `Get-ConsumerIssues` (Task 12); `Restore-PathAFiles`, `Invoke-PathA` and the test helper `New-T16Ctx` (Task 16); `Invoke-PathB`, `Invoke-PathBRollback` (Task 17).
- Produces:
  - `Get-AuditState -Ctx <hashtable>` → nothing. Runs the spec 7.4 SSPI baseline, which is the whole spec 7.9 test: `Test-PgSspiLogin`, then (only when the login passes) `Test-PgConfigHealth`; `DbAuth` can be `WINDOWS` only when both pass. Fills `$Ctx.State` (`RegistryAuth`, `SspiPassed`, `DbAuth`, `PgHba`, `PgIdent`, `PgPassword`, `Backends`) and `$script:Report` (`DbAuth`, `PgHba`, `PgIdent`, `PgPassword`, `SvcAccount`). Adds exit-5 issues, blockers first (`PG_PASSWORD_CONSUMER`/`PG_REMOTE_CONSUMER` from `Get-ConsumerIssues`, `SERVICE_ACCOUNT_UNRESOLVED`, `DB_AUTH_UNKNOWN`, `PATH_B_PREVIOUS_FAILURE`), then drift (`DB_NATIVE_AUTH`, `DB_HOST_NOT_LOCAL`, `DB_WINDOWS_ROLE_NOT_POSTGRES`, `PG_HBA_NOT_STANDARD`, `PG_IDENT_NOT_STANDARD`, `PG_POSTGRES_PASSWORD_SET`).
  - `Select-ApplyPath -Ctx <hashtable>` → `NONE`, `A`, `B` or `BLOCKED` (spec 7.6; reads `$script:Issues` for blocker codes).
  - `Invoke-TrapHandler -ErrorRecord <System.Management.Automation.ErrorRecord>` → does not return (ends in `Complete-Run`). Reads `$script:Stage` and `$script:Ctx` defensively; sets the re-entry guard `$script:TrapHandled`.
  - `Exit-IfConstrainedLanguage -LanguageMode <string> [-Mode <string> = 'AUDIT']` → returns nothing in `FullLanguage`; otherwise prints the RMM summary block for `CONSTRAINED_LANGUAGE` with `Write-Host` only and exits 20. Constrained Language Mode blocks `New-Object` for the run lock, the issue list and `Complete-Run`, so the main body calls this before spec 7.1 step 1 (measured: without it the script stops on `New-Object System.Collections.ArrayList` with no summary).
  - The main body below `# ===================== MAIN =====================`. It also adds the translated SYSTEM name (`Get-SystemMapNames`) to the required `pg_ident.conf` names (spec 7.3: every name comes from a SID), and passes the path's `Detail` to `Complete-Run` on success too, as a note (spec 7.5 and 7.6 Path B step 13).

- [ ] **Step 1: Write the failing tests**

Insert this block just above the line `# ===================== RESULT =====================` in `Test-VbrStandardise.ps1`. It has seven parts: static policy checks on `$ScriptText`/`$ScriptAst`, `Get-AuditState` with every database function mocked, the `Select-ApplyPath` decision table, `Invoke-TrapHandler` with a `Complete-Run` mock that throws a sentinel, three child-process runs of the real script (AUDIT without VBR, `pwsh.exe`, and Constrained Language Mode through a wrapper that switches its own session to `ConstrainedLanguage`), a child-process driver for the success note of `Complete-Run`, and the required-names checks. The child runs only read the machine. The `powershell.exe` run uses a new WorkRoot `C:\ProgramData\vbrstd-t18child-<PID>` (a `%TEMP%` parent can fail the WorkRoot trust check of Task 3 on some machines); the test adds it to `$script:TestFolders`, so the RESULT section removes it.

```powershell
# --- Task 18: Main body, audit, trap and policy tests ---
# Static policy checks on the script text and AST.
$t18MainMarker = '# ===================== MAIN ====================='
$t18MainIndex = $ScriptText.IndexOf($t18MainMarker)
Check 'T18 MAIN line present' ($t18MainIndex -ge 0) 'True'
$t18MainText = ''
if ($t18MainIndex -ge 0) { $t18MainText = $ScriptText.Substring($t18MainIndex) }

$t18Params = @($ScriptAst.ParamBlock.Parameters)
Check 'T18 param block is exactly Apply, CreateServiceAccount, WorkRoot' ((@($t18Params | ForEach-Object { $_.Name.VariablePath.UserPath }) | Sort-Object) -join ',') 'Apply,CreateServiceAccount,WorkRoot'
Check 'T18 Apply is a switch' (@($t18Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Apply' -and $_.StaticType -eq [switch] }).Count) 1
Check 'T18 CreateServiceAccount is a switch' (@($t18Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'CreateServiceAccount' -and $_.StaticType -eq [switch] }).Count) 1
Check 'T18 WorkRoot default' (@($t18Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'WorkRoot' } | ForEach-Object { "$($_.DefaultValue.Value)" }) -join ',') 'C:\ProgramData\VeeamStandardise'

$t18Commands = @($ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
function Get-T18CommandUse {
    param([string[]] $Names)
    return @($t18Commands | Where-Object { $Names -contains "$($_.GetCommandName())" })
}
function Test-T18ParameterUse {
    param($Command, [string] $FullName, [int] $MinLength)
    foreach ($element in @($Command.CommandElements)) {
        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
            $element.ParameterName.Length -ge $MinLength -and
            $FullName.StartsWith($element.ParameterName, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
Check 'T18 forbidden: Stop-Service -Force' (@(Get-T18CommandUse 'Stop-Service', 'spsv' | Where-Object { Test-T18ParameterUse -Command $_ -FullName 'Force' -MinLength 1 }).Count) 0
Check 'T18 forbidden: Stop-Process' (@(Get-T18CommandUse 'Stop-Process', 'kill', 'spps').Count) 0
Check 'T18 forbidden: Get-LocalGroupMember' (@(Get-T18CommandUse 'Get-LocalGroupMember', 'glgm').Count) 0
Check 'T18 forbidden: Read-Host' (@(Get-T18CommandUse 'Read-Host').Count) 0
Check 'T18 forbidden: Out-File' (@(Get-T18CommandUse 'Out-File').Count) 0
Check 'T18 forbidden: Invoke-Expression' (@(Get-T18CommandUse 'Invoke-Expression', 'iex').Count) 0
$t18Utf8Writes = @(Get-T18CommandUse 'Set-Content', 'sc' | Where-Object {
    $elements = @($_.CommandElements)
    $hit = $false
    for ($i = 1; $i -lt $elements.Count; $i++) {
        $element = $elements[$i]
        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
            $element.ParameterName.Length -ge 2 -and 'Encoding'.StartsWith($element.ParameterName, [StringComparison]::OrdinalIgnoreCase)) {
            $argument = $element.Argument
            if ($null -eq $argument -and $i + 1 -lt $elements.Count) { $argument = $elements[$i + 1] }
            if ($null -ne $argument -and "$($argument.Extent.Text)".Trim([char[]]"'`"") -ieq 'UTF8') { $hit = $true }
        }
    }
    $hit
})
Check 'T18 forbidden: Set-Content -Encoding UTF8' $t18Utf8Writes.Count 0
$t18LiteralSecure = @(Get-T18CommandUse 'ConvertTo-SecureString' | Where-Object {
    $command = $_
    $literal = @(@($command.CommandElements) | Select-Object -Skip 1 | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] }).Count -gt 0
    if ($command.Parent -is [System.Management.Automation.Language.PipelineAst]) {
        $first = $command.Parent.PipelineElements[0]
        if ($first -ne $command -and $first -is [System.Management.Automation.Language.CommandExpressionAst] -and
            $first.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $literal = $true }
    }
    $literal
})
Check 'T18 forbidden: ConvertTo-SecureString with a literal' $t18LiteralSecure.Count 0
Check 'T18 password is never read as $env:VEEAM_SVC_PASSWORD' (@($ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and "$($n.VariablePath.UserPath)" -ieq 'env:VEEAM_SVC_PASSWORD' }, $true)).Count) 0

Check 'T18 every function is above MAIN' (@($ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Extent.StartOffset -gt $t18MainIndex }).Count) 0
$t18Traps = @($ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TrapStatementAst] }, $true))
Check 'T18 exactly one trap, below MAIN' (@($t18Traps | Where-Object { $_.Extent.StartOffset -gt $t18MainIndex }).Count * 10 + $t18Traps.Count) 11
Check 'T18 trap calls Invoke-TrapHandler' (@($t18Traps | ForEach-Object { $_.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-TrapHandler' }, $true) }).Count) 1
Check 'T18 main body never calls exit itself' (@($ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true) | Where-Object { $_.Extent.StartOffset -gt $t18MainIndex }).Count) 0
Check 'T18 mode string is APPLY or AUDIT' ($t18MainText -match '\$runMode = if \(\$Apply\) \{ ''APPLY'' \} else \{ ''AUDIT'' \}') 'True'
Check 'T18 lock name' ($t18MainText.Contains("Enter-RunLock -Name 'Global\VeeamPgUpdate'")) 'True'
Check 'T18 transcript file name' ($t18MainText.Contains("'logs\VbrStandardise_{0}_{1}-{2}.log' -f `$env:COMPUTERNAME, `$runStamp, `$PID")) 'True'
$t18Order = @('Enter-RunLock', 'Get-PreflightContextIssue', 'Initialize-WorkRoot', 'Start-Transcript', 'Find-ChangeMarkers', 'Remove-OldRunData',
              'Test-IsDomainController', 'Get-VbrInstall', 'Get-VbrDbConfig', 'Test-Vb365Installed', 'Get-DbHostClass', 'Find-PgInstall',
              'Test-PostmasterLive', 'Test-PgConfOverride', 'Test-PgHbaHasInclude', 'Get-ListeningLoopback', 'Get-SystemMapNames',
              'Invoke-ServiceAccountStep', 'Get-AuditState', 'Select-ApplyPath', 'Invoke-PathA', 'Invoke-PathB', 'Complete-Run @finish')
$t18OrderProblem = 'in order'
$t18Previous = -1
foreach ($t18Name in $t18Order) {
    $t18Position = $t18MainText.IndexOf($t18Name)
    if ($t18Position -le $t18Previous) { $t18OrderProblem = "$t18Name is missing or out of order"; break }
    $t18Previous = $t18Position
}
Check 'T18 main body follows spec 7.1 order, then 7.2 to 7.6' $t18OrderProblem 'in order'

# Get-AuditState with every database function mocked.
$t18AuditMocks = {
    $calls = New-Object System.Collections.ArrayList
    $fake = @{
        RegistryAuth = 'WINDOWS'; HostClass = 'LOOPBACK'; HbaStandard = $true; IdentStatus = 'STANDARD'
        SspiPassed = $true; HealthOk = $true; LiveOk = $true; PasswordSet = $false; BackendsOk = $true
        Backends = @([pscustomobject]@{ Pid = 10; UseName = 'postgres'; DatName = 'VeeamBackup'; ClientAddr = '127.0.0.1'; BackendStartUtc = [DateTime]::UtcNow })
        FirstMethod = 'sspi'; FirstOptions = 'map=veeam'; Consumers = @(); RemoteClients = @(); LastFailure = $false; NonLoopback = @()
    }
    function Get-RegistryAuthMode { param($UserName, $PasswordSet) return $fake.RegistryAuth }
    function Get-DbHostClass { param($HostName, $LocalNames) return $fake.HostClass }
    function Test-PgHbaStandard { param($Rules) return [bool]$fake.HbaStandard }
    function Get-PgIdentStatus { param($Entries, $RequiredNames) return $fake.IdentStatus }
    function Test-PgSspiLogin {
        param($Psql, $Port, $Addresses, $Database)
        [void]$calls.Add('Test-PgSspiLogin')
        $kind = 'OK'
        if (-not $fake.SspiPassed) { $kind = 'AUTH' }
        return [pscustomobject]@{ Passed = [bool]$fake.SspiPassed; Results = @(@($Addresses) | ForEach-Object { [pscustomobject]@{ Address = $_; ExitCode = 0; Kind = $kind; StdErr = '' } }) }
    }
    function Test-PgConfigHealth {
        param($Psql, $Port, $Address, $Database, $Major, $HbaPath, $IdentPath)
        [void]$calls.Add('Test-PgConfigHealth')
        return [pscustomobject]@{ Ok = [bool]$fake.HealthOk; Detail = "live hba_file is 'D:/other/pg_hba.conf', not '$HbaPath'" }
    }
    function Get-PgLiveState { param($Psql, $Port, $Address, $Database) [void]$calls.Add('Get-PgLiveState'); return [pscustomobject]@{ Ok = [bool]$fake.LiveOk; PasswordSet = [bool]$fake.PasswordSet; Backends = @($fake.Backends) } }
    function Test-VbrBackendsOk { param($Backends, $Database) return [bool]$fake.BackendsOk }
    function Get-HbaFirstMatch {
        param($Rules, $Database, $User, $Address)
        [void]$calls.Add("Get-HbaFirstMatch:${User}:$Address")
        return [pscustomobject]@{ LineIndex = 0; Type = 'host'; Database = 'all'; User = 'all'; Address = '127.0.0.1/32'; Method = $fake.FirstMethod; Options = $fake.FirstOptions }
    }
    function Get-DbAuthState {
        param($RegistryAuth, $SspiPassed, $FirstMatchOk, $VbrBackendsOk)
        if ($RegistryAuth -eq 'NATIVE') { return 'NATIVE' }
        if ($SspiPassed -and $FirstMatchOk -and $VbrBackendsOk) { return 'WINDOWS' }
        return 'UNKNOWN'
    }
    function Get-EstablishedRemoteClients { param($Port) [void]$calls.Add('Get-EstablishedRemoteClients'); return @($fake.RemoteClients) }
    function Get-ConsumerIssues {
        param($DbConfig, $EmConfig, $Backends, $RemoteClients, $LocalNames)
        [void]$calls.Add("Get-ConsumerIssues:backends=$($null -ne $Backends):remote=$(@($RemoteClients).Count)")
        return @($fake.Consumers)
    }
    function Get-NonLoopbackHbaRules { param($Rules) return @($fake.NonLoopback) }
    function Test-LastFailure { param($WorkRoot) return [bool]$fake.LastFailure }
}

# A compliant Windows-auth server: no issues, all report fields set.
& {
    . $t18AuditMocks
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'AUDIT'
    $ctx = New-T16Ctx
    $ctx.HbaRules = @([pscustomobject]@{ LineIndex = 0; Type = 'host'; Database = 'all'; User = 'all'; Address = '127.0.0.1/32'; Method = 'sspi'; Options = 'map=veeam' })
    Get-AuditState -Ctx $ctx
    Check 'T18 audit compliant: DbAuth WINDOWS' $ctx.State['DbAuth'] 'WINDOWS'
    Check 'T18 audit compliant: PgPassword NONE' $ctx.State['PgPassword'] 'NONE'
    Check 'T18 audit compliant: SspiPassed' $ctx.State['SspiPassed'] 'True'
    Check 'T18 audit compliant: no issues' @($script:Issues).Count 0
    Check 'T18 audit compliant: first match checked per address' (@($calls | Where-Object { $_ -like 'Get-HbaFirstMatch:*' }) -join ',') 'Get-HbaFirstMatch:postgres:127.0.0.1,Get-HbaFirstMatch:postgres:::1'
    Check 'T18 audit compliant: consumers from pg_stat_activity' (@($calls | Where-Object { $_ -like 'Get-ConsumerIssues*' }) -join ',') 'Get-ConsumerIssues:backends=True:remote=0'
    Check 'T18 audit compliant: no TCP fallback' (@($calls | Where-Object { $_ -eq 'Get-EstablishedRemoteClients' }).Count) 0
    Check 'T18 audit compliant: the config check is part of the baseline' (@($calls | Where-Object { $_ -eq 'Test-PgConfigHealth' }).Count) 1
    Check 'T18 audit compliant: report fields' ("$($script:Report['DbAuth']) $($script:Report['PgHba']) $($script:Report['PgIdent']) $($script:Report['PgPassword']) $($script:Report['SvcAccount'])") 'WINDOWS STANDARD STANDARD NONE OK'
}

# A native-auth server: SYSTEM cannot log in yet, TCP fallback for consumers.
& {
    . $t18AuditMocks
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'AUDIT'
    $fake.RegistryAuth = 'NATIVE'
    $fake.SspiPassed = $false
    $fake.HbaStandard = $false
    $fake.IdentStatus = 'MISSING_ENTRY'
    $ctx = New-T16Ctx
    Get-AuditState -Ctx $ctx
    Check 'T18 audit native: DbAuth NATIVE' $ctx.State['DbAuth'] 'NATIVE'
    Check 'T18 audit native: PgPassword UNKNOWN' $ctx.State['PgPassword'] 'UNKNOWN'
    Check 'T18 audit native: no live query' (@($calls | Where-Object { $_ -eq 'Get-PgLiveState' }).Count) 0
    Check 'T18 audit native: no config check without an SSPI login' (@($calls | Where-Object { $_ -eq 'Test-PgConfigHealth' }).Count) 0
    Check 'T18 audit native: consumers from TCP' (@($calls | Where-Object { $_ -like 'Get-ConsumerIssues*' -or $_ -eq 'Get-EstablishedRemoteClients' }) -join ',') 'Get-EstablishedRemoteClients,Get-ConsumerIssues:backends=False:remote=0'
    Check 'T18 audit native: drift issues' ((@($script:Issues) | ForEach-Object { $_.Code }) -join ',') 'DB_NATIVE_AUTH,PG_HBA_NOT_STANDARD,PG_IDENT_NOT_STANDARD'
    Check 'T18 audit native: all exit 5' ((@($script:Issues) | ForEach-Object { $_.ExitCode } | Sort-Object -Unique) -join ',') '5'
}

# Registry says Windows, but the first pg_hba line for postgres is scram -> UNKNOWN.
& {
    . $t18AuditMocks
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'AUDIT'
    $fake.FirstMethod = 'scram-sha-256'
    $fake.FirstOptions = ''
    $ctx = New-T16Ctx
    Get-AuditState -Ctx $ctx
    Check 'T18 audit unknown: DbAuth UNKNOWN' $ctx.State['DbAuth'] 'UNKNOWN'
    Check 'T18 audit unknown: DB_AUTH_UNKNOWN reported' ((@($script:Issues) | ForEach-Object { $_.Code }) -join ',') 'DB_AUTH_UNKNOWN'
    Check 'T18 audit unknown: says why' ($script:Issues[0].Detail -like "*first pg_hba.conf line for postgres from 127.0.0.1*") 'True'
    $fake.FirstMethod = 'sspi'
    $fake.FirstOptions = @('map=Veeam')
    $script:Issues.Clear()
    Get-AuditState -Ctx $ctx
    Check 'T18 audit unknown: map name compares case-sensitively' $ctx.State['DbAuth'] 'UNKNOWN'
}

# The SSPI baseline is the whole spec 7.9 test: a failed config check (here a live
# hba_file that is not the file in the data folder) makes DbAuth UNKNOWN, even when
# the login works. The live state is still read.
& {
    . $t18AuditMocks
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'AUDIT'
    $fake.HealthOk = $false
    $ctx = New-T16Ctx
    Get-AuditState -Ctx $ctx
    Check 'T18 audit config check fails: DbAuth UNKNOWN' $ctx.State['DbAuth'] 'UNKNOWN'
    Check 'T18 audit config check fails: DB_AUTH_UNKNOWN says why' (@($script:Issues | Where-Object { $_.Code -eq 'DB_AUTH_UNKNOWN' -and $_.Detail -like "*the PostgreSQL config check failed (live hba_file is 'D:/other/pg_hba.conf'*" }).Count) 1
    Check 'T18 audit config check fails: live state still read' $ctx.State['PgPassword'] 'NONE'
}

# Blockers come before drift; consumer Action is kept; LAN lines are listed.
& {
    . $t18AuditMocks
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'APPLY'
    $fake.PasswordSet = $true
    $fake.HbaStandard = $false
    $fake.HostClass = 'LOCAL'
    $fake.LastFailure = $true
    $fake.Consumers = @([pscustomobject]@{ Code = 'PG_PASSWORD_CONSUMER'; Detail = 'pg_native_admin from 127.0.0.1'; Action = 'Move the client to Windows authentication, then re-run' })
    $fake.NonLoopback = @([pscustomobject]@{ LineIndex = 94; Type = 'host'; Database = 'all'; User = 'all'; Address = '10.0.0.0/8'; Method = 'scram-sha-256'; Options = '' })
    $ctx = New-T16Ctx
    $ctx.HbaRules = @($fake.NonLoopback)
    $ctx.Db.HostName = 'VBR01'
    $ctx.Db.WindowsAuthRole = 'Postgres'
    $ctx.ServiceAccounts = [pscustomobject]@{ MapNames = @(); Unresolved = @('NT AUTHORITY\NetworkService') }
    Get-AuditState -Ctx $ctx
    Check 'T18 audit order: blockers first, then drift' ((@($script:Issues) | ForEach-Object { $_.Code }) -join ',') ('PG_PASSWORD_CONSUMER,SERVICE_ACCOUNT_UNRESOLVED,PATH_B_PREVIOUS_FAILURE,' +
        'DB_HOST_NOT_LOCAL,DB_WINDOWS_ROLE_NOT_POSTGRES,PG_HBA_NOT_STANDARD,PG_POSTGRES_PASSWORD_SET')
    Check 'T18 audit order: consumer action kept' $script:Issues[0].Action 'Move the client to Windows authentication, then re-run'
    Check 'T18 audit order: unresolved StartName in Detail' ($script:Issues[1].Detail -like '*NT AUTHORITY\NetworkService*') 'True'
    Check 'T18 audit order: LAN line in PG_HBA_NOT_STANDARD' (@($script:Issues | Where-Object { $_.Code -eq 'PG_HBA_NOT_STANDARD' -and $_.Detail -like '*line 95: host all all 10.0.0.0/8 scram-sha-256*' }).Count) 1
    Check 'T18 audit order: PgPassword SET' $ctx.State['PgPassword'] 'SET'
}

# An empty PostgresUserForWindowsAuth is not drift.
& {
    . $t18AuditMocks
    $script:Issues = New-Object System.Collections.ArrayList
    $script:Report = New-RunReport -Mode 'AUDIT'
    $ctx = New-T16Ctx
    $ctx.Db.WindowsAuthRole = ''
    Get-AuditState -Ctx $ctx
    Check 'T18 audit: empty Windows-auth role is not drift' @($script:Issues).Count 0
}

# Select-ApplyPath decision table (spec 7.6).
& {
    function Get-DbHostClass {
        param($HostName, $LocalNames)
        if (@('localhost', '127.0.0.1', '::1') -contains $HostName) { return 'LOOPBACK' }
        if (@($LocalNames) -contains $HostName) { return 'LOCAL' }
        return 'REMOTE'
    }
    function Get-T18Path {
        param([string] $DbAuth, [string] $Hba = 'STANDARD', [string] $Ident = 'STANDARD', [string] $Password = 'NONE',
              [string] $HostName = '127.0.0.1', [string] $Role = 'postgres', [bool] $BlocksDb = $false, [string[]] $IssueCodes = @(), [switch] $NoAccount)
        $script:Issues = New-Object System.Collections.ArrayList
        foreach ($code in $IssueCodes) { $null = Add-RunIssue -Code $code -ExitCode 5 -Detail 'test' }
        $ctx = New-T16Ctx -PgHba $Hba -PgIdent $Ident -PgPassword $Password
        $ctx.State['DbAuth'] = $DbAuth
        $ctx.Db.HostName = $HostName
        $ctx.Db.WindowsAuthRole = $Role
        $ctx.Account = [pscustomobject]@{ Status = 'OK'; Info = $null; BlocksDb = $BlocksDb }
        if ($NoAccount) { $ctx.Account = $null }
        return (Select-ApplyPath -Ctx $ctx)
    }
    Check 'T18 path: compliant -> NONE' (Get-T18Path -DbAuth 'WINDOWS') 'NONE'
    Check 'T18 path: Windows, pg_hba drift -> A' (Get-T18Path -DbAuth 'WINDOWS' -Hba 'NOT_STANDARD') 'A'
    Check 'T18 path: Windows, pg_ident drift -> A' (Get-T18Path -DbAuth 'WINDOWS' -Ident 'EXTRA_ENTRY') 'A'
    Check 'T18 path: Windows, password set -> A' (Get-T18Path -DbAuth 'WINDOWS' -Password 'SET') 'A'
    Check 'T18 path: native -> B' (Get-T18Path -DbAuth 'NATIVE' -Hba 'NOT_STANDARD' -Ident 'MISSING_ENTRY' -Password 'UNKNOWN') 'B'
    Check 'T18 path: Windows, host is the server name -> B' (Get-T18Path -DbAuth 'WINDOWS' -HostName 'VBR01') 'B'
    Check 'T18 path: Windows, other Windows-auth role -> B' (Get-T18Path -DbAuth 'WINDOWS' -Role 'veeamsql') 'B'
    Check 'T18 path: role Postgres differs by case -> B' (Get-T18Path -DbAuth 'WINDOWS' -Role 'Postgres') 'B'
    Check 'T18 path: empty role is fine -> NONE' (Get-T18Path -DbAuth 'WINDOWS' -Role '') 'NONE'
    Check 'T18 path: UNKNOWN -> BLOCKED' (Get-T18Path -DbAuth 'UNKNOWN' -IssueCodes @('DB_AUTH_UNKNOWN')) 'BLOCKED'
    Check 'T18 path: UNKNOWN with host drift -> BLOCKED' (Get-T18Path -DbAuth 'UNKNOWN' -HostName 'VBR01') 'BLOCKED'
    Check 'T18 path: native, account missing -> BLOCKED' (Get-T18Path -DbAuth 'NATIVE' -BlocksDb $true) 'BLOCKED'
    Check 'T18 path: native, no account object -> BLOCKED' (Get-T18Path -DbAuth 'NATIVE' -NoAccount) 'BLOCKED'
    Check 'T18 path: compliant DB, account missing -> NONE' (Get-T18Path -DbAuth 'WINDOWS' -BlocksDb $true) 'NONE'
    Check 'T18 path: password consumer -> BLOCKED' (Get-T18Path -DbAuth 'WINDOWS' -Hba 'NOT_STANDARD' -IssueCodes @('PG_PASSWORD_CONSUMER')) 'BLOCKED'
    Check 'T18 path: remote consumer -> BLOCKED' (Get-T18Path -DbAuth 'WINDOWS' -Password 'SET' -IssueCodes @('PG_REMOTE_CONSUMER')) 'BLOCKED'
    Check 'T18 path: unresolved service account -> BLOCKED' (Get-T18Path -DbAuth 'NATIVE' -IssueCodes @('SERVICE_ACCOUNT_UNRESOLVED')) 'BLOCKED'
    Check 'T18 path: last-failure blocks B' (Get-T18Path -DbAuth 'NATIVE' -IssueCodes @('PATH_B_PREVIOUS_FAILURE')) 'BLOCKED'
    Check 'T18 path: last-failure does not block A' (Get-T18Path -DbAuth 'WINDOWS' -Hba 'NOT_STANDARD' -IssueCodes @('PATH_B_PREVIOUS_FAILURE')) 'A'
    Check 'T18 path: a disabled account does not block' (Get-T18Path -DbAuth 'WINDOWS' -Hba 'NOT_STANDARD' -IssueCodes @('SVC_DISABLED', 'SVC_LOCKED_OUT')) 'A'
}

# Invoke-TrapHandler: the stage decides; Complete-Run always ends it.
try { throw 'disk is full' } catch { $t18Error = $_ }
$t18TrapMocks = {
    $calls = New-Object System.Collections.ArrayList
    $completed = New-Object System.Collections.ArrayList
    $fake = @{ Restored = $true; Rollback = $null }
    function Complete-Run {
        param([int] $ExitCode = 0, [string] $Code = '', [string] $Detail = '', [string] $Action = '')
        [void]$completed.Add([pscustomobject]@{ ExitCode = $ExitCode; Code = $Code; Detail = $Detail; Action = $Action })
        throw 'T18-COMPLETE-RUN'
    }
    function Restore-PathAFiles { param($Ctx) [void]$calls.Add('Restore-PathAFiles'); return [bool]$fake.Restored }
    function Invoke-PathBRollback { param($Ctx, $Reason) [void]$calls.Add("Invoke-PathBRollback:$Reason"); return $fake.Rollback }
    function Remove-ChangeMarker { param($WorkRoot) [void]$calls.Add('Remove-ChangeMarker'); return $true }
    function Invoke-T18Trap {
        param([string] $Stage)
        $script:Stage = $Stage
        $script:TrapHandled = $false
        $script:Issues = New-Object System.Collections.ArrayList
        $calls.Clear()
        $completed.Clear()
        $sentinel = ''
        try { Invoke-TrapHandler -ErrorRecord $t18Error } catch { $sentinel = "$($_.Exception.Message)" }
        $handled = [bool]$script:TrapHandled
        $script:TrapHandled = $false
        return "$sentinel/$handled"
    }
}
& {
    . $t18TrapMocks
    $script:Ctx = New-T16Ctx
    $script:LogLines.Clear()
    Check 'T18 trap UNTOUCHED: ends in Complete-Run, guard set' (Invoke-T18Trap -Stage 'UNTOUCHED') 'T18-COMPLETE-RUN/True'
    Check 'T18 trap UNTOUCHED: 20 UNHANDLED_ERROR' "$($completed[0].ExitCode) $($completed[0].Code)" '20 UNHANDLED_ERROR'
    Check 'T18 trap UNTOUCHED: message in Detail' ($completed[0].Detail -like 'disk is full*') 'True'
    Check 'T18 trap UNTOUCHED: no restore or rollback' $calls.Count 0
    Check 'T18 trap: error logged' (@($script:LogLines | Where-Object { $_ -like '`[ERROR`] UNHANDLED ERROR at stage UNTOUCHED: disk is full*' }).Count) 1

    $null = Invoke-T18Trap -Stage 'PATH_A_WRITING'
    Check 'T18 trap PATH_A_WRITING restored: restore then marker' ($calls -join ' > ') 'Restore-PathAFiles > Remove-ChangeMarker'
    Check 'T18 trap PATH_A_WRITING restored: 40 UNHANDLED_ERROR' "$($completed[0].ExitCode) $($completed[0].Code)" '40 UNHANDLED_ERROR'

    $fake.Restored = $false
    $null = Invoke-T18Trap -Stage 'PATH_A_WRITING'
    Check 'T18 trap PATH_A_WRITING not restored: marker stays' ($calls -join ' > ') 'Restore-PathAFiles'
    Check 'T18 trap PATH_A_WRITING not restored: 50 ROLLBACK_FAILED' "$($completed[0].ExitCode) $($completed[0].Code)" '50 ROLLBACK_FAILED'
    Check 'T18 trap PATH_A_WRITING not restored: the error is kept as an issue' ((@($script:Issues) | ForEach-Object { "$($_.Code)/$($_.ExitCode)" }) -join ',') 'UNHANDLED_ERROR/40'

    $fake.Rollback = [pscustomobject]@{ ExitCode = 40; Code = 'UNHANDLED_ERROR'; Detail = 'rolled back'; Action = 'ESCALATE. test action' }
    $null = Invoke-T18Trap -Stage 'PATH_B_CHANGING'
    Check 'T18 trap PATH_B_CHANGING: runs the Path B rollback' ($calls[0] -like 'Invoke-PathBRollback:UNHANDLED_ERROR: disk is full*') 'True'
    Check 'T18 trap PATH_B_CHANGING: result of the rollback' "$($completed[0].ExitCode) $($completed[0].Code) $($completed[0].Action)" '40 UNHANDLED_ERROR ESCALATE. test action'

    $fake.Rollback = $null
    $null = Invoke-T18Trap -Stage 'PATH_B_CHANGING'
    Check 'T18 trap PATH_B_CHANGING: no rollback result -> 50' "$($completed[0].ExitCode) $($completed[0].Code)" '50 ROLLBACK_FAILED'

    foreach ($stage in @('PATH_A_DONE', 'VERIFIED')) {
        $null = Invoke-T18Trap -Stage $stage
        Check "T18 trap ${stage}: marker removed, nothing rolled back" ($calls -join ' > ') 'Remove-ChangeMarker'
        Check "T18 trap ${stage}: 5 POST_CONVERSION_STEP_FAILED" "$($completed[0].ExitCode) $($completed[0].Code)" '5 POST_CONVERSION_STEP_FAILED'
    }
    $script:Ctx = $null
}
$script:Stage = 'UNTOUCHED'
$script:Issues = New-Object System.Collections.ArrayList

# Child process runs of the real script. The WorkRoot is a new folder under
# C:\ProgramData, the parent of the default WorkRoot, because a %TEMP% parent can
# fail the WorkRoot trust check on some machines. The RESULT section removes it.
$t18ScriptPath = Join-Path $PSScriptRoot 'Invoke-VbrStandardise.ps1'
$t18VbrCorePath = Get-RegValue -Path 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication' -Name 'CorePath'
$t18ChildWorkRoot = Join-Path $env:ProgramData "vbrstd-t18child-$PID"
$t18PwshWorkRoot = Join-Path $env:ProgramData "vbrstd-t18pwsh-$PID"
[void]$script:TestFolders.Add($t18ChildWorkRoot)
[void]$script:TestFolders.Add($t18PwshWorkRoot)
if (-not (Test-IsAdministrator)) {
    Skip 'T18 child AUDIT without VBR exits 20 VBR_NOT_FOUND' 'not elevated'
} elseif ($t18VbrCorePath) {
    Skip 'T18 child AUDIT without VBR exits 20 VBR_NOT_FOUND' 'this machine has a VBR server'
} elseif (Test-IsDomainController) {
    Skip 'T18 child AUDIT without VBR exits 20 VBR_NOT_FOUND' 'this machine is a domain controller'
} elseif (@(Find-ChangeMarkers -WorkRoot $t18ChildWorkRoot).Count -gt 0) {
    Skip 'T18 child AUDIT without VBR exits 20 VBR_NOT_FOUND' 'an updater marker exists on this machine'
} else {
    $t18PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $t18PowerShell = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe' }
    $t18Child = & {
        $ErrorActionPreference = 'Continue'
        $output = (& $t18PowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $t18ScriptPath -WorkRoot $t18ChildWorkRoot 2>&1 | Out-String)
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    Check 'T18 child AUDIT without VBR: exit 20' $t18Child.ExitCode 20
    Check 'T18 child AUDIT without VBR: IssueCode VBR_NOT_FOUND' ($t18Child.Output -match 'IssueCode=VBR_NOT_FOUND(;|\s|$)') 'True'
    Check 'T18 child AUDIT without VBR: summary block' ($t18Child.Output -match '=== RMM SUMMARY ===') 'True'
    Check 'T18 child AUDIT without VBR: Mode=AUDIT' ($t18Child.Output -match 'Mode=AUDIT') 'True'
    Check 'T18 child AUDIT without VBR: last-result.json written' (Test-Path -LiteralPath (Join-Path $t18ChildWorkRoot 'logs\last-result.json')) 'True'
    Check 'T18 child AUDIT without VBR: no run folder' (@(Get-ChildItem -LiteralPath (Join-Path $t18ChildWorkRoot 'runs') -Force -ErrorAction SilentlyContinue).Count) 0
}
$t18Pwsh = @(Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue)
if ($t18Pwsh.Count -eq 0) {
    Skip 'T18 child under pwsh exits 20 WRONG_POWERSHELL' 'pwsh.exe not found'
} else {
    $t18PwshChild = & {
        $ErrorActionPreference = 'Continue'
        $output = (& $t18Pwsh[0].Path -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $t18ScriptPath -WorkRoot $t18PwshWorkRoot 2>&1 | Out-String)
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    Check 'T18 child under pwsh: exit 20' $t18PwshChild.ExitCode 20
    Check 'T18 child under pwsh: IssueCode WRONG_POWERSHELL' ($t18PwshChild.Output -match 'IssueCode=WRONG_POWERSHELL(;|\s|$)') 'True'
    Check 'T18 child under pwsh: nothing written' (Test-Path -LiteralPath $t18PwshWorkRoot) 'False'
}

# Constrained Language Mode (spec 7.1 step 3). A wrapper switches its own session to
# ConstrainedLanguage and runs the real script, which then runs in that mode too. The
# script must report CONSTRAINED_LANGUAGE before the lock and before any .NET type
# that mode blocks. Needs no elevation, VBR or PostgreSQL, so it never skips.
$t18ClmRoot = Join-Path $env:ProgramData "vbrstd-t18clm-$PID"
[void]$script:TestFolders.Add($t18ClmRoot)
$t18ClmWrapper = Join-Path (New-TestFolder 't18clm') 'clm.ps1'
$t18ClmText = "`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'`r`n" +
    "& '" + $t18ScriptPath.Replace("'", "''") + "' -Apply -WorkRoot '" + $t18ClmRoot.Replace("'", "''") + "'`r`n" +
    "exit `$LASTEXITCODE`r`n"
[System.IO.File]::WriteAllText($t18ClmWrapper, $t18ClmText, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
$t18ClmPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $t18ClmPowerShell = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe' }
$t18ClmChild = & {
    $ErrorActionPreference = 'Continue'
    $output = (& $t18ClmPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $t18ClmWrapper 2>&1 | Out-String)
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}
$t18ClmLine = @($t18ClmChild.Output -split "`r?`n" | Where-Object { $_ -clike 'Computer=*' })
$t18ClmKeys = ''
if ($t18ClmLine.Count -eq 1) { $t18ClmKeys = (@([regex]::Matches($t18ClmLine[0], '(?:^|; )([A-Za-z]+)=') | ForEach-Object { $_.Groups[1].Value }) -join ',') }
Check 'T18 child in Constrained Language Mode: exit 20' $t18ClmChild.ExitCode 20
Check 'T18 child in Constrained Language Mode: IssueCode CONSTRAINED_LANGUAGE' ($t18ClmChild.Output -match 'IssueCode=CONSTRAINED_LANGUAGE(;|\s|$)') 'True'
Check 'T18 child in Constrained Language Mode: one summary line with every report field in order' $t18ClmKeys (@((New-RunReport -Mode 'APPLY').Keys) -join ',')
Check 'T18 child in Constrained Language Mode: Mode=APPLY, Stage=UNTOUCHED' (@($t18ClmLine | Where-Object { $_ -clike '*; Mode=APPLY; *; Stage=UNTOUCHED; Outcome=CONSTRAINED_LANGUAGE; ExitCode=20; *' }).Count) 1
Check 'T18 child in Constrained Language Mode: no error record' ($t18ClmChild.Output -match 'Cannot create type|Cannot invoke method|UNHANDLED') 'False'
Check 'T18 child in Constrained Language Mode: nothing written' (Test-Path -LiteralPath $t18ClmRoot) 'False'

# Complete-Run (Task 2) with -Detail and no -Code adds a note to Detail. The main body
# passes the notes of a successful path that way (spec 7.5: commented-out pg_hba.conf
# lines; spec 7.6 Path B step 13: roles that lost their login). Complete-Run exits,
# so a driver with the real function texts runs in a child powershell.exe.
$t18Fn = @{}
foreach ($t18Statement in $ScriptAst.EndBlock.Statements) {
    if ($t18Statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $t18Fn[$t18Statement.Name] = $t18Statement.Extent.Text }
}
$t18NoteNeeded = @('Format-ShortText', 'Write-Log', 'Write-AtomicText', 'Write-AtomicJson', 'Get-CfgValue', 'New-RunReport', 'Add-RunIssue', 'Get-RmmActionForExitCode', 'Resolve-RunOutcome', 'Format-RmmSummary', 'Complete-Run')
$t18NoteHead = @'
param([string] $Scenario, [string] $Root)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
function Exit-RunLock { param($Mutex) }
'@
$t18NoteBody = @'
$WorkRoot = $Root
$script:Report = New-RunReport -Mode 'APPLY'
$script:WorkRootReady = $true
if ($Scenario -eq 'issue') { Add-RunIssue -Code 'SVC_DISABLED' -ExitCode 5 -Detail 'svc_veeam is disabled' }
Complete-Run -ExitCode 0 -Detail 'Commented out pg_hba.conf line 95: host all all 10.0.0.0/8 scram-sha-256.'
'@
$t18NoteDriver = Join-Path (New-TestFolder 't18note') 'driver.ps1'
$t18NoteFunctions = (@($t18NoteNeeded | Where-Object { $t18Fn.ContainsKey($_) } | ForEach-Object { $t18Fn[$_] }) -join "`r`n`r`n")
[System.IO.File]::WriteAllText($t18NoteDriver, ($t18NoteHead + "`r`n" + $t18NoteFunctions + "`r`n" + $t18NoteBody), (New-Object System.Text.UTF8Encoding -ArgumentList $false))
$t18NotePowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$t18NoteText = 'Commented out pg_hba.conf line 95: host all all 10.0.0.0/8 scram-sha-256.'
$t18NoteRoot = New-TestFolder 't18noteok'
$t18NoteOk = Invoke-Native -FilePath $t18NotePowerShell -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $t18NoteDriver, '-Scenario', 'ok', '-Root', $t18NoteRoot)
$t18NoteOkLines = @($t18NoteOk.StdOut -split "`r?`n")
Check 'T18 success note: exit 0' $t18NoteOk.ExitCode 0
Check 'T18 success note: in Detail, with no issue' (@($t18NoteOkLines | Where-Object { $_ -clike ('*; Outcome=OK; ExitCode=0; IssueCode=; ActionRequired=None; Detail=' + $t18NoteText + '; *') }).Count) 1
Check 'T18 success note: no RMM ISSUE line' (@($t18NoteOkLines | Where-Object { $_ -clike 'RMM ISSUE:*' }).Count) 0
$t18NoteJsonPath = Join-Path $t18NoteRoot 'logs\last-result.json'
$t18NoteJsonDetail = ''
if (Test-Path -LiteralPath $t18NoteJsonPath) { $t18NoteJsonDetail = "$(([System.IO.File]::ReadAllText($t18NoteJsonPath) | ConvertFrom-Json).Detail)" }
Check 'T18 success note: in last-result.json' $t18NoteJsonDetail $t18NoteText
$t18NoteIssue = Invoke-Native -FilePath $t18NotePowerShell -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $t18NoteDriver, '-Scenario', 'issue', '-Root', (New-TestFolder 't18noteissue'))
Check 'T18 note after an issue: exit 5' $t18NoteIssue.ExitCode 5
Check 'T18 note after an issue: the issue first, then the note' (@($t18NoteIssue.StdOut -split "`r?`n" | Where-Object { $_ -clike ('*; IssueCode=SVC_DISABLED; *; Detail=SVC_DISABLED: svc_veeam is disabled | ' + $t18NoteText + '; *') }).Count) 1
Check 'T18 main body passes the path Detail to Complete-Run on success too' ($t18MainText.Contains('if ("$($pathResult.Detail)") { $finish[''Detail''] = "$($pathResult.Detail)" }')) 'True'

# Spec 7.3: the SYSTEM line comes from S-1-5-18. The main body adds the translated
# name to the required names; Get-RequiredIdentNames keeps Veeam's English line first
# and drops the translated one when it is the same name.
$t18RequiredLine = @($t18MainText -split "`r?`n" | Where-Object { $_ -like '*Get-RequiredIdentNames -SvcMapName*' })
Check 'T18 required names: the main body adds the translated SYSTEM name' (($t18RequiredLine.Count -eq 1) -and $t18RequiredLine[0].Contains('@("$($systemNames.Translated)")')) 'True'
Check 'T18 required names: English SYSTEM line kept, translated one added' (@(Get-RequiredIdentNames -SvcMapName 'svc_veeam@VBR01' -ServiceAccountMapNames @('SISTEMA@AUTORIDADE NT', 'veeamsvc@CORP')) -join '|') 'SYSTEM@NT AUTHORITY|svc_veeam@VBR01|SISTEMA@AUTORIDADE NT|veeamsvc@CORP'
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: every check up to Task 17 prints `PASS`. These Task 18 checks FAIL:
- the main-body checks: `T18 exactly one trap, below MAIN  expected '11' got '0'`, `T18 trap calls Invoke-TrapHandler`, `T18 main body never calls exit itself` (the Task 1 placeholder calls `exit`), `T18 mode string is APPLY or AUDIT`, `T18 lock name`, `T18 transcript file name`, and `T18 main body follows spec 7.1 order, then 7.2 to 7.6  expected 'in order' got 'Enter-RunLock is missing or out of order'`;
- six `FAIL  UNHANDLED  The term 'Get-AuditState' is not recognized as the name of a cmdlet, function, script file, or operable program.` lines and one for `Select-ApplyPath`;
- `T18 trap UNTOUCHED: ends in Complete-Run, guard set` (it got `The term 'Invoke-TrapHandler' is not recognized as the name of a cmdlet, function, script file, or operable program.` and the spelling hint, then `/False`), then one `FAIL  UNHANDLED  The property 'ExitCode' cannot be found on this object.`;
- the child runs: the placeholder exits 20 without a summary, so `IssueCode VBR_NOT_FOUND`, `summary block`, `Mode=AUDIT`, `last-result.json written` and `IssueCode WRONG_POWERSHELL` FAIL (their exit-code checks already pass). The Constrained Language Mode run FAILS `IssueCode CONSTRAINED_LANGUAGE`, `one summary line with every report field in order` (`got ''`) and `Mode=APPLY, Stage=UNTOUCHED`; its `exit 20`, `no error record` and `nothing written` checks already pass on the placeholder;
- `T18 main body passes the path Detail to Complete-Run on success too` and `T18 required names: the main body adds the translated SYSTEM name`.

The six `T18 success note` / `T18 note after an issue` checks and `T18 required names: English SYSTEM line kept, translated one added` already PASS: they test `Complete-Run` (Task 2) and `Get-RequiredIdentNames` (Task 10), which the main body relies on.

The run ends with `RESULT: <n> passed, 26 failed` (`RESULT: 1339 passed, 26 failed` on an elevated prompt on English Windows without PostgreSQL or VBR, with `pwsh.exe` installed; 22 failed when the `powershell.exe` child run is skipped, 25 when `pwsh.exe` is missing) and exit code 1. The forbidden-command and parameter checks already PASS, because no earlier task uses a forbidden command; they guard later edits.

- [ ] **Step 3: Implement**

Insert this code just above the line `#endregion MainHelpers` in `Invoke-VbrStandardise.ps1`:

```powershell
# Spec 7.3-7.5: read the database state, fill $Ctx.State and the report fields,
# and add the drift and blocker issues (all exit 5). Blockers are added first, so
# that with equal exit codes the RMM IssueCode names what stops the change.
# AUDIT and APPLY both run this; it changes nothing.
function Get-AuditState {
    param([Parameter(Mandatory)][hashtable] $Ctx)
    $db = $Ctx.Db
    $pg = $Ctx.Pg
    $addresses = @($Ctx.Addresses)
    $database = "$($db.DatabaseName)"
    $localNames = @($Ctx.LocalNames | Where-Object { $_ })
    $hbaRules = @($Ctx.HbaRules | Where-Object { $null -ne $_ })
    $state = @{
        RegistryAuth = 'NATIVE'; SspiPassed = $false; DbAuth = 'UNKNOWN'
        PgHba = 'NOT_STANDARD'; PgIdent = 'MISSING_ENTRY'; PgPassword = 'UNKNOWN'; Backends = $null
    }
    $Ctx['State'] = $state

    $state['RegistryAuth'] = Get-RegistryAuthMode -UserName "$($db.UserName)" -PasswordSet ([bool]$db.PasswordSet)
    $hostClass = Get-DbHostClass -HostName "$($db.HostName)" -LocalNames $localNames
    $role = "$($db.WindowsAuthRole)"
    $roleDrift = ($role -ne '' -and $role -cne 'postgres')

    if (Test-PgHbaStandard -Rules $hbaRules) { $state['PgHba'] = 'STANDARD' }
    $state['PgIdent'] = "$(Get-PgIdentStatus -Entries @($Ctx.IdentEntries | Where-Object { $null -ne $_ }) -RequiredNames @($Ctx.RequiredIdentNames))"

    # Spec 7.4: the SSPI baseline is the whole spec 7.9 test, run before any change:
    # the login on every listening address, then the config check (the files that
    # PostgreSQL loads parse without errors, and SHOW hba_file/ident_file name the
    # files this script edits). WINDOWS needs both parts. The login alone decides
    # whether the live state can be read.
    $sspi = Test-PgSspiLogin -Psql "$($pg.Psql)" -Port ([int]$pg.Port) -Addresses $addresses -Database $database
    $state['SspiPassed'] = [bool]$sspi.Passed
    $healthOk = $false
    $firstMatchOk = $false
    $backendsOk = $false
    $whyUnknown = New-Object System.Collections.ArrayList
    if ($state['SspiPassed']) {
        $health = Test-PgConfigHealth -Psql "$($pg.Psql)" -Port ([int]$pg.Port) -Address $addresses[0] -Database $database -Major ([int]$pg.Major) -HbaPath "$($pg.HbaPath)" -IdentPath "$($pg.IdentPath)"
        $healthOk = [bool]$health.Ok
        if (-not $healthOk) { [void]$whyUnknown.Add("the PostgreSQL config check failed ($($health.Detail))") }
        $live = Get-PgLiveState -Psql "$($pg.Psql)" -Port ([int]$pg.Port) -Address $addresses[0] -Database $database
        if ($live.Ok) {
            if ($live.PasswordSet) { $state['PgPassword'] = 'SET' } else { $state['PgPassword'] = 'NONE' }
            $state['Backends'] = @($live.Backends | Where-Object { $null -ne $_ })
            $backendsOk = [bool](Test-VbrBackendsOk -Backends $state['Backends'] -Database $database)
            if (-not $backendsOk) { [void]$whyUnknown.Add('a VBR backend in pg_stat_activity is not postgres from loopback') }
        } else {
            [void]$whyUnknown.Add('pg_stat_activity could not be read')
        }
        $firstMatchOk = $true
        foreach ($address in $addresses) {
            $match = Get-HbaFirstMatch -Rules $hbaRules -Database $database -User 'postgres' -Address $address
            $options = @()
            if ($null -ne $match) { $options = @(("$(@($match.Options) -join ' ')") -split '\s+' | Where-Object { $_ }) }
            if ($null -eq $match -or "$($match.Method)" -ne 'sspi' -or -not ($options -ccontains 'map=veeam')) {
                $firstMatchOk = $false
                [void]$whyUnknown.Add("the first pg_hba.conf line for postgres from $address is not 'sspi map=veeam'")
            }
        }
    } else {
        $failed = @($sspi.Results | Where-Object { $null -ne $_ -and "$($_.Kind)" -ne 'OK' } | ForEach-Object { "$($_.Address) $($_.Kind)" })
        [void]$whyUnknown.Add('SYSTEM cannot log in over SSPI (' + ($failed -join ', ') + ')')
    }
    $state['DbAuth'] = "$(Get-DbAuthState -RegistryAuth $state['RegistryAuth'] -SspiPassed ($state['SspiPassed'] -and $healthOk) -FirstMatchOk $firstMatchOk -VbrBackendsOk $backendsOk)"

    # Spec 7.5 consumers: from pg_stat_activity when SYSTEM can log in, else from TCP.
    if ($state['SspiPassed'] -and $null -ne $state['Backends']) {
        $consumers = @(Get-ConsumerIssues -DbConfig $db -EmConfig $Ctx['Em'] -Backends $state['Backends'] -RemoteClients @() -LocalNames $localNames)
    } else {
        $remoteClients = @(Get-EstablishedRemoteClients -Port ([int]$pg.Port))
        $consumers = @(Get-ConsumerIssues -DbConfig $db -EmConfig $Ctx['Em'] -Backends $null -RemoteClients $remoteClients -LocalNames $localNames)
    }

    # Blockers first.
    foreach ($consumer in @($consumers | Where-Object { $null -ne $_ })) {
        $null = Add-RunIssue -Code "$($consumer.Code)" -ExitCode 5 -Detail "$($consumer.Detail)" -Action "$($consumer.Action)"
    }
    $unresolved = @($Ctx.ServiceAccounts.Unresolved | Where-Object { $_ })
    if ($unresolved.Count -gt 0) {
        $null = Add-RunIssue -Code 'SERVICE_ACCOUNT_UNRESOLVED' -ExitCode 5 -Detail ('Veeam service account(s) that cannot be mapped: ' + ($unresolved -join ', ') + '. No veeam map line is removed and no database change is made.') -Action 'Check the account of each Veeam service named in Detail (NetworkService, LocalService and gMSA accounts are not supported), then re-run'
    }
    if ($state['DbAuth'] -eq 'UNKNOWN') {
        $null = Add-RunIssue -Code 'DB_AUTH_UNKNOWN' -ExitCode 5 -Detail ("The registry says $($state['RegistryAuth']), but " + ($whyUnknown -join '; ') + '.') -Action 'Check by hand how VBR logs in to PostgreSQL on this server; the script makes no database change while this is unknown'
    }
    if (Test-LastFailure -WorkRoot $Ctx.WorkRoot) {
        $null = Add-RunIssue -Code 'PATH_B_PREVIOUS_FAILURE' -ExitCode 5 -Detail "An earlier Path B run failed and was rolled back: $(Join-Path $Ctx.WorkRoot 'last-failure.json')" -Action 'Read the run folder named in last-failure.json, fix the cause, delete last-failure.json, then re-run with -Apply'
    }

    # Drift.
    if ($state['DbAuth'] -eq 'NATIVE') {
        $null = Add-RunIssue -Code 'DB_NATIVE_AUTH' -ExitCode 5 -Detail 'VBR logs in to PostgreSQL with a user name and password (registry SqlUserName or SqlSecuredPassword is set).' -Action 'Re-run with -Apply in a maintenance window'
    }
    if ($hostClass -ne 'LOOPBACK') {
        $null = Add-RunIssue -Code 'DB_HOST_NOT_LOCAL' -ExitCode 5 -Detail "SqlHostName is '$($db.HostName)', not localhost, 127.0.0.1 or ::1." -Action 'Re-run with -Apply in a maintenance window'
    }
    if ($roleDrift) {
        $null = Add-RunIssue -Code 'DB_WINDOWS_ROLE_NOT_POSTGRES' -ExitCode 5 -Detail "PostgresUserForWindowsAuth is '$role', not postgres." -Action 'Re-run with -Apply in a maintenance window'
    }
    if ($state['PgHba'] -ne 'STANDARD') {
        $lanText = ''
        if ($hbaRules.Count -gt 0) {
            $lan = @(Get-NonLoopbackHbaRules -Rules $hbaRules | ForEach-Object { "line $([int]$_.LineIndex + 1): $($_.Type) $($_.Database) $($_.User) $($_.Address) $($_.Method)" })
            if ($lan.Count -gt 0) { $lanText = ' Lines for other addresses that -Apply comments out: ' + ($lan -join '; ') + '.' }
        }
        $null = Add-RunIssue -Code 'PG_HBA_NOT_STANDARD' -ExitCode 5 -Detail ("The active pg_hba.conf lines are not Veeam's six SSPI lines.$lanText") -Action 'Re-run with -Apply'
    }
    if ($state['PgIdent'] -ne 'STANDARD') {
        $null = Add-RunIssue -Code 'PG_IDENT_NOT_STANDARD' -ExitCode 5 -Detail ("The veeam map in pg_ident.conf is $($state['PgIdent']). Required: " + (@($Ctx.RequiredIdentNames) -join ', ') + '.') -Action 'Re-run with -Apply'
    }
    if ($state['PgPassword'] -eq 'SET') {
        $null = Add-RunIssue -Code 'PG_POSTGRES_PASSWORD_SET' -ExitCode 5 -Detail 'The postgres role still has a password.' -Action 'Re-run with -Apply'
    }

    $reportVar = Get-Variable -Name Report -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $reportVar -and $reportVar.Value -is [System.Collections.IDictionary]) {
        $report = $reportVar.Value
        $report['DbAuth'] = $state['DbAuth']
        $report['PgHba'] = $state['PgHba']
        $report['PgIdent'] = $state['PgIdent']
        $report['PgPassword'] = $state['PgPassword']
        if ($null -ne $Ctx['Account']) { $report['SvcAccount'] = "$(Get-CfgValue -Object $Ctx['Account'] -Name 'Status' -Default 'UNKNOWN')" }
    }
}

# Spec 7.6: which path -Apply takes. NONE = nothing to change; BLOCKED = a change
# is needed but a prerequisite fails (the reason is already in the issues).
function Select-ApplyPath {
    param([Parameter(Mandatory)][hashtable] $Ctx)
    $state = $Ctx['State']
    $db = $Ctx.Db
    $dbAuth = "$($state['DbAuth'])"
    $hostClass = Get-DbHostClass -HostName "$($db.HostName)" -LocalNames @($Ctx.LocalNames | Where-Object { $_ })
    $role = "$($db.WindowsAuthRole)"
    $needsB = ($dbAuth -eq 'NATIVE') -or ($hostClass -ne 'LOOPBACK') -or ($role -ne '' -and $role -cne 'postgres')
    $needsA = (-not $needsB) -and ($dbAuth -eq 'WINDOWS') -and
              (("$($state['PgHba'])" -ne 'STANDARD') -or ("$($state['PgIdent'])" -ne 'STANDARD') -or ("$($state['PgPassword'])" -eq 'SET'))
    if ($dbAuth -eq 'WINDOWS' -and -not $needsA -and -not $needsB) { return 'NONE' }

    $reasons = New-Object System.Collections.ArrayList
    $account = $Ctx['Account']
    if ($null -eq $account -or [bool](Get-CfgValue -Object $account -Name 'BlocksDb' -Default $true)) {
        [void]$reasons.Add('svc_veeam is missing or not in Administrators')
    }
    if ($dbAuth -ne 'WINDOWS' -and $dbAuth -ne 'NATIVE') { [void]$reasons.Add("DbAuth is $dbAuth") }
    $blockCodes = @('PG_PASSWORD_CONSUMER', 'PG_REMOTE_CONSUMER', 'SERVICE_ACCOUNT_UNRESOLVED', 'DB_AUTH_UNKNOWN')
    if ($needsB) { $blockCodes += 'PATH_B_PREVIOUS_FAILURE' }
    $issuesVar = Get-Variable -Name Issues -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $issuesVar -and $null -ne $issuesVar.Value) {
        foreach ($issue in @($issuesVar.Value)) {
            if ($null -ne $issue -and $blockCodes -contains "$($issue.Code)") { [void]$reasons.Add("$($issue.Code)") }
        }
    }
    if ($reasons.Count -gt 0) {
        Write-Log ('No database change, because: ' + ($reasons -join ', ')) -Level WARN
        return 'BLOCKED'
    }
    if ($needsB) { return 'B' }
    return 'A'
}

# Called by the script's trap. Decides by stage (spec 7.6 table, through
# Get-TrapAction) and always ends in Complete-Run, which exits. A second error
# while this handler runs (for example inside Complete-Run) prints a minimal
# summary and exits 50 without repeating any restore or rollback.
function Invoke-TrapHandler {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord] $ErrorRecord)
    $message = "$($ErrorRecord.Exception.Message)"
    if ($null -ne $ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.ScriptLineNumber -gt 0) {
        $message += " (line $($ErrorRecord.InvocationInfo.ScriptLineNumber))"
    }
    $stage = "$(Get-Variable -Name Stage -Scope Script -ValueOnly -ErrorAction SilentlyContinue)"
    if (-not $stage) { $stage = 'UNTOUCHED' }

    if ([bool](Get-Variable -Name TrapHandled -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
        Write-Host '=== RMM SUMMARY ==='
        Write-Host ("Computer=$env:COMPUTERNAME; Stage=$stage; Outcome=UNHANDLED_ERROR; ExitCode=50; IssueCode=UNHANDLED_ERROR; " +
                    'ActionRequired=PAGE AN OPERATOR NOW. Check the transcript and the marker.; Detail=' +
                    (Format-ShortText -Text "A second unexpected error happened while handling the first: $message"))
        Write-Host '==================='
        exit 50
    }
    $script:TrapHandled = $true
    Write-Log "UNHANDLED ERROR at stage ${stage}: $message" -Level ERROR

    $ctxVar = Get-Variable -Name Ctx -Scope Script -ErrorAction SilentlyContinue
    $ctx = $null
    if ($null -ne $ctxVar -and $ctxVar.Value -is [hashtable]) { $ctx = $ctxVar.Value }
    $workRoot = ''
    if ($null -ne $ctx) { $workRoot = "$($ctx['WorkRoot'])" }

    $action = Get-TrapAction -Stage $stage
    if ($action -eq 'RESTORE_PATH_A') {
        $restored = $false
        if ($null -ne $ctx) {
            try { $restored = [bool](Restore-PathAFiles -Ctx $ctx) } catch { $restored = $false }
        }
        if ($restored) {
            $markerNote = ''
            try { if (-not (Remove-ChangeMarker -WorkRoot $workRoot)) { $markerNote = ' The marker could not be removed.' } } catch { $markerNote = ' The marker could not be removed.' }
            Complete-Run -ExitCode 40 -Code 'UNHANDLED_ERROR' -Detail "$message; both config files were restored from the run folder and SYSTEM can log in again.$markerNote"
        }
        $null = Add-RunIssue -Code 'UNHANDLED_ERROR' -ExitCode 40 -Detail $message
        Complete-Run -ExitCode 50 -Code 'ROLLBACK_FAILED' -Detail 'Restoring pg_hba.conf and pg_ident.conf after an unexpected error failed, or SYSTEM still cannot log in. The marker stays.' -Action 'PAGE AN OPERATOR NOW. VBR may not be able to open new database connections. Follow the MARKER_PRESENT recovery steps in README.md.'
    }
    if ($action -eq 'ROLLBACK_PATH_B') {
        $rollback = $null
        if ($null -ne $ctx) {
            try { $rollback = Invoke-PathBRollback -Ctx $ctx -Reason "UNHANDLED_ERROR: $message" } catch { $rollback = $null }
        }
        if ($null -eq $rollback) {
            $rollback = [pscustomobject]@{
                ExitCode = 50; Code = 'ROLLBACK_FAILED'
                Detail   = "UNHANDLED_ERROR: $message; the Path B rollback could not run. The marker stays."
                Action   = 'PAGE AN OPERATOR NOW. VBR may be down. Follow the MARKER_PRESENT recovery steps in README.md.'
            }
        }
        $finish = @{ ExitCode = [int]$rollback.ExitCode; Code = "$($rollback.Code)"; Detail = "$($rollback.Detail)" }
        $rollbackAction = "$(Get-CfgValue -Object $rollback -Name 'Action' -Default '')"
        if ($rollbackAction) { $finish['Action'] = $rollbackAction }
        Complete-Run @finish
    }
    if ($action -eq 'NO_ROLLBACK') {
        if ($workRoot) {
            try { $null = Remove-ChangeMarker -WorkRoot $workRoot } catch { Write-Log "The marker could not be removed: $($_.Exception.Message)" -Level WARN }
        }
        Complete-Run -ExitCode 5 -Code 'POST_CONVERSION_STEP_FAILED' -Detail "$message; the change was verified before this error and VBR works, so nothing was rolled back." -Action 'Check the transcript, then re-run with -Apply to finish the remaining steps'
    }
    Complete-Run -ExitCode 20 -Code 'UNHANDLED_ERROR' -Detail "$message; no database change was made."
}

# Spec 7.1 step 3 for Constrained Language Mode, which cannot wait for its turn: that
# mode blocks New-Object for the run lock (step 1), the issue list and Complete-Run,
# so the run would end in an error with no RMM summary. The main body calls this
# first. It uses only strings, Get-Date and Write-Host, which that mode allows, prints
# the RMM summary block with every report field in Format-RmmSummary's layout, and
# exits 20. In FullLanguage it does nothing. Nothing is locked, checked or written.
function Exit-IfConstrainedLanguage {
    param(
        [string] $LanguageMode,
        [string] $Mode = 'AUDIT'
    )
    if ($LanguageMode -eq 'FullLanguage') { return }
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK', [System.Globalization.CultureInfo]::InvariantCulture)
    $action = 'Allow this script in the application control policy (WDAC or AppLocker) so it runs in FullLanguage mode'
    $detail = "CONSTRAINED_LANGUAGE: PowerShell language mode is '$LanguageMode'. This script needs FullLanguage. Nothing was checked or changed."
    Write-Host ''
    Write-Host '=== RMM SUMMARY ==='
    Write-Host ("Computer=$env:COMPUTERNAME; Timestamp=$stamp; Mode=$Mode; VbrVersion=; PgMajor=; SvcAccount=UNKNOWN; DbAuth=UNKNOWN; " +
                'PgHba=UNKNOWN; PgIdent=UNKNOWN; PgPassword=UNKNOWN; Stage=UNTOUCHED; Outcome=CONSTRAINED_LANGUAGE; ExitCode=20; ' +
                "IssueCode=CONSTRAINED_LANGUAGE; ActionRequired=$action; Detail=$detail; LogPath=")
    Write-Host "RMM ACTION: $action"
    Write-Host "RMM ISSUE: CONSTRAINED_LANGUAGE | $detail"
    Write-Host '==================='
    exit 20
}
```

Then replace everything from the line `# ===================== MAIN =====================` to the end of `Invoke-VbrStandardise.ps1` (the MAIN line and the placeholder below it from Task 1) with:

```powershell
# ===================== MAIN =====================
# Everything above this line is a function. The test file loads those functions and
# never runs this part. The order below is spec section 7.1, then 7.2 to 7.6.

trap {
    Invoke-TrapHandler -ErrorRecord $_
}

$runMode = if ($Apply) { 'APPLY' } else { 'AUDIT' }
# 7.1 step 3, Constrained Language Mode only, comes before everything else: that mode
# blocks the .NET types that the lock (step 1), the issue list and Complete-Run need.
Exit-IfConstrainedLanguage -LanguageMode "$($ExecutionContext.SessionState.LanguageMode)" -Mode $runMode

$script:Stage = 'UNTOUCHED'
$script:Issues = New-Object System.Collections.ArrayList
$script:WorkRootReady = $false
$script:TranscriptStarted = $false
$script:RunLock = $null
$script:TrapHandled = $false
$Ctx = $null
$script:Report = New-RunReport -Mode $runMode
$config = Get-DefaultConfig
$exitCodes = Get-ExitCodeTable

# 7.1 step 1: the lock shared with Update-VeeamPostgres.ps1. If it is held, check nothing else.
$script:RunLock = Enter-RunLock -Name 'Global\VeeamPgUpdate'
if ($null -eq $script:RunLock) {
    Complete-Run -ExitCode $exitCodes.RETRY -Code 'CONCURRENT_RUN' -Detail 'Another process holds the Global\VeeamPgUpdate lock (this script or Update-VeeamPostgres.ps1). Nothing was checked.'
}

# 7.1 steps 2 and 3: Windows PowerShell 5.1 Desktop, elevated, 64-bit, FullLanguage.
$contextIssue = Get-PreflightContextIssue -PSEdition "$($PSVersionTable.PSEdition)" -IsAdmin (Test-IsAdministrator) -Is64BitOS ([Environment]::Is64BitOperatingSystem) -Is64BitProcess ([Environment]::Is64BitProcess) -LanguageMode "$($ExecutionContext.SessionState.LanguageMode)"
if ($null -ne $contextIssue) {
    Complete-Run -ExitCode ([int]$contextIssue.ExitCode) -Code "$($contextIssue.Code)" -Detail "$($contextIssue.Detail)" -Action "$($contextIssue.Action)"
}

# 7.1 step 4: the work folder. Nothing is written there before it passes.
$workRootError = ''
if ([string]::IsNullOrWhiteSpace($WorkRoot) -or $WorkRoot -notmatch '^[A-Za-z]:[\\/]') {
    $workRootError = "WorkRoot '$WorkRoot' must be an absolute path on a local drive."
} else {
    try { $WorkRoot = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\') } catch { $workRootError = "WorkRoot '$WorkRoot' is not a valid path: $($_.Exception.Message)" }
}
if (-not $workRootError) {
    $workRootResult = Initialize-WorkRoot -Path $WorkRoot
    if (-not $workRootResult.Ok) { $workRootError = "$($workRootResult.Detail)" }
}
if ($workRootError) {
    Complete-Run -ExitCode $exitCodes.PREFLIGHT -Code 'WORKROOT_UNSAFE' -Detail $workRootError -Action 'Use a WorkRoot that only SYSTEM and Administrators control (default C:\ProgramData\VeeamStandardise)'
}
$script:WorkRootReady = $true
$runStamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$transcriptPath = Join-Path $WorkRoot ('logs\VbrStandardise_{0}_{1}-{2}.log' -f $env:COMPUTERNAME, $runStamp, $PID)
try {
    $null = Start-Transcript -Path $transcriptPath -IncludeInvocationHeader
    $script:TranscriptStarted = $true
    $script:Report['LogPath'] = $transcriptPath
} catch {
    Write-Log "The transcript could not start: $($_.Exception.Message)" -Level WARN
}
Write-Log "Invoke-VbrStandardise.ps1 - mode $runMode" -Level STEP
Write-Log "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)); WorkRoot $WorkRoot; CreateServiceAccount $([bool]$CreateServiceAccount)"

# 7.1 step 5: a marker from an unfinished run of this script or of the updater.
$markers = @(Find-ChangeMarkers -WorkRoot $WorkRoot)
if ($markers.Count -gt 0) {
    Complete-Run -ExitCode $exitCodes.ESCALATE_NOW -Code 'MARKER_PRESENT' -Detail ('A run stopped in the middle of a change. Marker: ' + ($markers -join ', ')) -Action 'PAGE AN OPERATOR NOW. Hold Update-VeeamPostgres.ps1 jobs on this server. Follow the MARKER_PRESENT recovery steps in README.md, then delete the marker.'
}
if (Test-LastFailure -WorkRoot $WorkRoot) {
    Write-Log 'last-failure.json exists, so old run folders are kept.' -Level WARN
} else {
    try { $null = Remove-OldRunData -WorkRoot $WorkRoot -RetentionDays ([int]$config.RetentionDays) } catch { Write-Log "Housekeeping failed: $($_.Exception.Message)" -Level WARN }
}

# 7.1 step 6
if (Test-IsDomainController) {
    Complete-Run -ExitCode $exitCodes.UNSUPPORTED -Code 'DOMAIN_CONTROLLER' -Detail 'This server is a domain controller, where a local account would be a domain account.'
}

# 7.1 step 7
$vbr = Get-VbrInstall
if (-not $vbr.Installed) {
    Complete-Run -ExitCode $exitCodes.PREFLIGHT -Code 'VBR_NOT_FOUND' -Detail 'No Veeam Backup & Replication server is installed (no CorePath under HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication).'
}
$script:Report['VbrVersion'] = "$($vbr.Version)"
$db = Get-VbrDbConfig
if ("$($db.ActiveConfiguration)" -ne 'PostgreSql') {
    Complete-Run -ExitCode $exitCodes.UNSUPPORTED -Code 'VBR_DB_NOT_POSTGRES' -Detail "SqlActiveConfiguration is '$($db.ActiveConfiguration)', not PostgreSql."
}

# 7.1 step 8
if (Test-Vb365Installed) {
    Complete-Run -ExitCode $exitCodes.UNSUPPORTED -Code 'STACKED_VBR_VB365' -Detail 'Veeam Backup for Microsoft 365 is installed on this server and shares the PostgreSQL instance.'
}

# 7.1 step 9 (DB_HOST_NOT_LOCAL and step 10's DB_WINDOWS_ROLE_NOT_POSTGRES are drift, reported by the audit)
$localNames = @(Get-LocalHostNames)
$hostClass = Get-DbHostClass -HostName "$($db.HostName)" -LocalNames $localNames
if ($hostClass -eq 'REMOTE') {
    Complete-Run -ExitCode $exitCodes.UNSUPPORTED -Code 'REMOTE_DB' -Detail "SqlHostName '$($db.HostName)' is not this server."
}

# 7.1 step 11
$pg = Find-PgInstall
if (-not $pg.Ok) {
    $pgCode = "$($pg.Code)"
    if (-not $pgCode) { $pgCode = 'NO_PG_FOUND' }
    $pgExit = $exitCodes.PREFLIGHT
    if ($pgCode -eq 'MULTIPLE_PG') { $pgExit = $exitCodes.UNSUPPORTED }
    Complete-Run -ExitCode $pgExit -Code $pgCode -Detail "$($pg.Detail)"
}
$script:Report['PgMajor'] = "$($pg.Major)"
if ($null -eq $db.Port) {
    Complete-Run -ExitCode $exitCodes.UNSUPPORTED -Code 'PG_INSTANCE_MISMATCH' -Detail 'SqlHostPort is missing from the VBR registry.'
}
$pg | Add-Member -NotePropertyName 'Port' -NotePropertyValue ([int]$db.Port) -Force

# 7.1 step 12
$postmaster = Test-PostmasterLive -DataDir "$($pg.DataDir)" -ExpectedPort ([int]$pg.Port)
if (-not $postmaster.Ok) {
    Complete-Run -ExitCode $exitCodes.UNSUPPORTED -Code 'PG_INSTANCE_MISMATCH' -Detail "$($postmaster.Detail)"
}

# 7.1 step 13
$overrides = @(Test-PgConfOverride -DataDir "$($pg.DataDir)")
if ($overrides.Count -gt 0) {
    Complete-Run -ExitCode $exitCodes.UNSUPPORTED -Code 'PG_CONF_OVERRIDE' -Detail ('postgresql.conf or postgresql.auto.conf sets ' + ($overrides -join ', ') + '.')
}
$hba = Read-ConfFile -Path "$($pg.HbaPath)"
$hbaLines = @(Split-ConfLines -Text $hba.Text)
if (Test-PgHbaHasInclude -Lines $hbaLines) {
    Complete-Run -ExitCode $exitCodes.UNSUPPORTED -Code 'PG_HBA_INCLUDE' -Detail "$($pg.HbaPath) uses include, include_if_exists, include_dir or an @file."
}

# 7.1 step 14
$addresses = @(Get-ListeningLoopback -Port ([int]$pg.Port))
if ($addresses.Count -eq 0) {
    Complete-Run -ExitCode $exitCodes.PREFLIGHT -Code 'PG_NOT_LISTENING' -Detail "Neither 127.0.0.1 nor ::1 listens on port $($pg.Port)."
}

# 7.1 step 15
$systemNames = Get-SystemMapNames
if (-not $systemNames.IsAscii) {
    Complete-Run -ExitCode $exitCodes.UNSUPPORTED -Code 'PG_IDENT_LOCALISED' -Detail "The SYSTEM account name '$($systemNames.Translated)' has non-ASCII characters."
}

# 7.2: the svc_veeam account (adds its own issues).
Write-Log 'Service account check' -Level STEP
$account = Invoke-ServiceAccountStep -Config $config -Apply ([bool]$Apply) -CreateRequested ([bool]$CreateServiceAccount)
$script:Report['SvcAccount'] = "$($account.Status)"

# 7.3: the names the veeam map must hold.
$serviceAccounts = Get-VeeamServiceAccountNames -ComputerName $env:COMPUTERNAME
$svcMapName = ''
if ($null -ne $account.Info -and [bool](Get-CfgValue -Object $account.Info -Name 'IsUser' -Default $false)) {
    $svcMapName = "$(Get-CfgValue -Object $account.Info -Name 'MapName' -Default '')"
}
if (-not $svcMapName) { $svcMapName = ConvertTo-SspiMapName -Domain $env:COMPUTERNAME -Name "$($config.ServiceAccountName)" }
# Spec 7.3 builds every name from a SID, SYSTEM from S-1-5-18. PostgreSQL sees the
# translated name, so on Windows whose SYSTEM name is translated but ASCII (for
# example SISTEMA@AUTORIDADE NT) that line is required next to Veeam's English one.
# On English Windows the two are the same name and the duplicate is dropped.
$requiredNames = @(Get-RequiredIdentNames -SvcMapName $svcMapName -ServiceAccountMapNames (@("$($systemNames.Translated)") + @($serviceAccounts.MapNames | Where-Object { $_ })))
$ident = Read-ConfFile -Path "$($pg.IdentPath)"
$identLines = @(Split-ConfLines -Text $ident.Text)

$Ctx = @{
    Config             = $config
    WorkRoot           = $WorkRoot
    Stamp              = $runStamp
    RunDir             = ''
    Apply              = [bool]$Apply
    CreateRequested    = [bool]$CreateServiceAccount
    Vbr                = $vbr
    Db                 = $db
    Em                 = (Get-EnterpriseManagerDbConfig)
    LocalNames         = $localNames
    Pg                 = $pg
    Addresses          = $addresses
    SystemNames        = $systemNames
    Account            = $account
    ServiceAccounts    = $serviceAccounts
    RequiredIdentNames = $requiredNames
    Hba                = $hba
    HbaLines           = $hbaLines
    HbaRules           = @(Get-PgHbaRules -Lines $hbaLines)
    Ident              = $ident
    IdentLines         = $identLines
    IdentEntries       = @(Get-PgIdentEntries -Lines $identLines)
    State              = @{}
    HbaBackupPath      = ''
    IdentBackupPath    = ''
    Snapshot           = @()
    StopSet            = @()
    Stopped            = @()
    RegSnapshot        = @{}
    RegBackup          = $null
    StartUtc           = [DateTime]::MinValue
    LogOffset          = [long]0
    PasswordCleared    = $false
}

# 7.4 and 7.5: live state, drift and blockers (both modes).
Write-Log 'Database state' -Level STEP
Get-AuditState -Ctx $Ctx
Write-Log ('DbAuth={0}; PgHba={1}; PgIdent={2}; PgPassword={3}; SvcAccount={4}' -f $Ctx.State['DbAuth'], $Ctx.State['PgHba'], $Ctx.State['PgIdent'], $Ctx.State['PgPassword'], $account.Status)
if (-not $Apply) {
    Write-Log 'AUDIT mode: no database change was made.'
    Complete-Run
}

# 7.6
$applyPath = Select-ApplyPath -Ctx $Ctx
Write-Log "Apply path: $applyPath" -Level STEP
if ($applyPath -eq 'NONE' -or $applyPath -eq 'BLOCKED') {
    Complete-Run
}
if ($applyPath -eq 'A') {
    $pathResult = Invoke-PathA -Ctx $Ctx
} else {
    $pathResult = Invoke-PathB -Ctx $Ctx
}
# The path's Detail goes to Complete-Run in every case. With a Code it is that issue's
# Detail; on success it is a note at the end of Detail (spec 7.5: the pg_hba.conf
# lines that were commented out; spec 7.6 Path B step 13: the roles that lost login).
if ("$($pathResult.Detail)") { Write-Log "Result: $($pathResult.Detail)" }
$finish = @{ ExitCode = [int]$pathResult.ExitCode }
if ("$($pathResult.Detail)") { $finish['Detail'] = "$($pathResult.Detail)" }
if ("$($pathResult.Code)") {
    $finish['Code'] = "$($pathResult.Code)"
    $pathAction = "$(Get-CfgValue -Object $pathResult -Name 'Action' -Default '')"
    if ($pathAction) { $finish['Action'] = $pathAction }
}
Complete-Run @finish
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`

Expected: `RESULT: <n> passed, 0 failed`, where `<n>` is the total after Task 17 plus 112 (`RESULT: 1422 passed, 0 failed` on an elevated prompt on English Windows without PostgreSQL or VBR, with `pwsh.exe` installed). A child run that cannot apply prints a `SKIP` line instead of its checks: plus 106 when the `powershell.exe` child run is skipped (not elevated, a VBR server with `CorePath`, a domain controller, or an updater marker on this machine), plus 109 when `pwsh.exe` is missing, plus 103 when both are skipped. The Constrained Language Mode run and the note driver never skip. Exit code 0.

Also run the same file under PowerShell 7, which must load the functions too: `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1`. Expected: the same `RESULT` line with 0 failed.

- [ ] **Step 5: Commit**

```powershell
git add Invoke-VbrStandardise.ps1 Test-VbrStandardise.ps1
git commit -m "Add main body, audit state, apply path choice and trap handler" -m "The main body runs the spec 7.1 preflight in order (lock first, transcript only after the WorkRoot passes), the account step, the audit and, with -Apply, Path A or Path B. Get-AuditState reports drift and blockers in both modes, blockers first. Select-ApplyPath holds every database change back unless the account, blockers and DbAuth allow it. The trap hands every unexpected error to Invoke-TrapHandler, which restores, rolls back or stops by stage. Constrained Language Mode is answered first with exit 20 CONSTRAINED_LANGUAGE, because that mode blocks the types the lock and the summary need. The translated SYSTEM name joins the required pg_ident.conf names, and a successful path's notes reach Detail. Static tests enforce the forbidden-command list and the parameter set; child runs prove VBR_NOT_FOUND, WRONG_POWERSHELL and CONSTRAINED_LANGUAGE." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 19: README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: none (documents the behaviour of Tasks 1-18, the exit codes of spec 6.2 and the issue codes of spec 6.3).
- Produces: `README.md`.

- [ ] **Step 1: Write README.md**

Create `README.md` in the project folder with exactly this content (UTF-8, no BOM):

````markdown
# Invoke-VbrStandardise.ps1

`Invoke-VbrStandardise.ps1` runs from RMM on Windows Veeam Backup & Replication (VBR) servers. It checks each server against one standard and, when asked, fixes it:

1. A local account `svc_veeam` exists. It is a member of the local Administrators group. Its password never expires, the user cannot change it, and the account never expires.
2. The VBR configuration database (PostgreSQL) uses Windows authentication (SSPI). No password login to PostgreSQL is possible: `pg_hba.conf` holds only Veeam's six SSPI lines, and the `postgres` role has no password.
3. The `veeam` map in `pg_ident.conf` maps only `SYSTEM`, `svc_veeam` and the account of any Veeam service that does not run as LocalSystem, to the `postgres` role. Every name is built from the account's SID. On Windows whose SYSTEM name is translated but plain ASCII (for example Portuguese `SISTEMA@AUTORIDADE NT`), the map holds the translated name as well as Veeam's English `SYSTEM@NT AUTHORITY` line, because PostgreSQL sees the translated name.

`svc_veeam` is the account that people use for Veeam upgrades, Veeam maintenance and PostgreSQL maintenance. It does not run any service. The Veeam services keep running as LocalSystem.

By default the script only reads and reports (AUDIT). It changes the server only with `-Apply` or `-CreateServiceAccount`.

## Files

| File | Purpose |
|---|---|
| `Invoke-VbrStandardise.ps1` | The script. It is one self-contained file, so RMM uploads a single file. |
| `Test-VbrStandardise.ps1` | Tests. Never copy it to a Veeam server or add it to RMM. |
| `README.md` | This file. |

## Scope

The script supports a Windows VBR server whose configuration database is PostgreSQL on the same server. It refuses (exit 11 `UNSUPPORTED`, or exit 20 where noted) and changes nothing on:

- VBR servers that use Microsoft SQL Server (`VBR_DB_NOT_POSTGRES`), or a database on another server (`REMOTE_DB`).
- VBR and Veeam Backup for Microsoft 365 on the same server (`STACKED_VBR_VB365`). VB365 shares the PostgreSQL instance and needs remote SSPI lines for its proxies.
- Domain controllers (`DOMAIN_CONTROLLER`).
- Non-English Windows where the SYSTEM account name has non-ASCII characters, for example `NT-AUTORITÄT` (`PG_IDENT_LOCALISED`).
- PostgreSQL setups the script cannot edit safely: more than one install (`MULTIPLE_PG`), a running instance that is not the one in the registry (`PG_INSTANCE_MISMATCH`), `hba_file` or `ident_file` set in `postgresql.conf` (`PG_CONF_OVERRIDE`), or `include` lines in `pg_hba.conf` (`PG_HBA_INCLUDE`).
- VBR on Linux and the Veeam Software Appliance.

The script never changes the account the Veeam services run as, never upgrades PostgreSQL (`Update-VeeamPostgres.ps1` does that), and has no recovery mode: if a run stops in the middle of a change, a person recovers the server with the steps in [MARKER_PRESENT: manual recovery](#marker_present-manual-recovery).

## Running from RMM

### Command

Run the script as **SYSTEM**, with **64-bit Windows PowerShell 5.1**:

```
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File Invoke-VbrStandardise.ps1 [-Apply] [-CreateServiceAccount]
```

- Do not use `pwsh.exe` (PowerShell 7). The script exits 20 `WRONG_POWERSHELL`. Under PowerShell 7 the LocalAccounts cmdlets run in a compatibility session, so their errors cannot be mapped to issue codes.
- If the RMM agent is a 32-bit process, use `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe`. A 32-bit host exits 20 `HOST_32BIT`.
- The script never prompts. It runs only from RMM.

### Timeout: 45 minutes or more

Set the RMM script timeout to **45 minutes or more**. The worst case is about 30 minutes: stopping the services (5), waiting for VBR to connect (10), stopping them again for a rollback (5), the rollback settle check (5), and the checks around them.

If RMM kills the script, the script cannot clean up. The change marker stays, and every later run exits 50 `MARKER_PRESENT` until a person recovers the server.

### Secure variable VEEAM_SVC_PASSWORD

The `svc_veeam` password comes from an RMM **secure variable** named `VEEAM_SVC_PASSWORD`, which RMM passes to the script as an environment variable. There is no password parameter.

- It is needed only with `-CreateServiceAccount`, and only when the account does not exist yet.
- Give each server its own password if your RMM can do that. A password that is shared across the fleet gives an attacker every backup server.
- The script reads the variable once, removes it from its own environment at once, and never writes the value to the log, the transcript, the summary or a file. It never puts it on a command line.
- The script never resets the password of an account that already exists.
- If the password does not meet the Windows password policy, nothing is created and the run reports `SVC_PASSWORD_POLICY`.

### Schedules

- **AUDIT** (no flags) is safe to run at any time, for example daily. It changes nothing.
- **`-Apply`** belongs in a maintenance window. Path A has no downtime, but Path B stops every running Veeam service (see [Maintenance window](#maintenance-window)).
- The script takes the `Global\VeeamPgUpdate` lock, which `Update-VeeamPostgres.ps1` also uses. If either script is running, the other exits 10 `CONCURRENT_RUN` at once and checks nothing else. Retry later.
- `Update-VeeamPostgres.ps1` does not know about this script's marker. **Hold updater jobs on any server that reports `MARKER_PRESENT` from this script.**

## Parameters

| Parameter | Effect |
|---|---|
| (none) | AUDIT. The script reads and reports. It changes nothing. `Mode=AUDIT`. |
| `-Apply` | APPLY. The script fixes every item except a missing account. `Mode=APPLY`. |
| `-CreateServiceAccount` | Creates `svc_veeam` if it is missing, with the three flags set, and adds it to Administrators. Needs `VEEAM_SVC_PASSWORD`. It can run alone or together with `-Apply`. Alone, it creates the account and then audits the rest (`Mode=AUDIT`). |
| `-WorkRoot <path>` | The work folder. The default is `C:\ProgramData\VeeamStandardise`. It must be an absolute path on a local drive that only SYSTEM and Administrators control. |

Common command lines:

| Goal | Flags |
|---|---|
| Report only | (none) |
| Create the account, report the rest | `-CreateServiceAccount` |
| Create the account and fix everything | `-Apply -CreateServiceAccount` |
| Fix everything (account already exists) | `-Apply` |

## What the script does

### 1. Preflight (every run, no changes)

In this order. The first failure ends the run. One exception: Constrained Language Mode (`CONSTRAINED_LANGUAGE`, exit 20) is checked before the lock, because that mode blocks the .NET types that the lock and the summary need.

1. Take the `Global\VeeamPgUpdate` lock (`CONCURRENT_RUN`, exit 10).
2. Windows PowerShell 5.1 Desktop (`WRONG_POWERSHELL`).
3. Elevated, 64-bit, FullLanguage (`NOT_ELEVATED`, `HOST_32BIT`, `CONSTRAINED_LANGUAGE`).
4. The WorkRoot passes its owner, ACL and reparse-point checks (`WORKROOT_UNSAFE`). Only after this does the transcript start.
5. No change marker from an unfinished run: this script's `<WorkRoot>\CHANGES-IN-PROGRESS.marker`, the updater's `C:\ProgramData\VeeamPgUpdate\CHANGES-IN-PROGRESS.marker`, or the updater's trusted legacy `C:\temp\VeeamPgUpdate\CHANGES-IN-PROGRESS.marker` (`MARKER_PRESENT`, exit 50).
6. Not a domain controller.
7. VBR is installed and uses PostgreSQL.
8. VB365 is not installed.
9. `SqlHostName` is this server. A name other than `localhost`, `127.0.0.1` or `::1` is drift `DB_HOST_NOT_LOCAL`.
10. `PostgresUserForWindowsAuth` is missing, empty or `postgres`. Any other value is drift `DB_WINDOWS_ROLE_NOT_POSTGRES`.
11. Exactly one PostgreSQL install, and its service runs.
12. `postmaster.pid` names a live `postgres.exe` on the VBR port.
13. No `hba_file`/`ident_file` override and no `include` in `pg_hba.conf`.
14. `127.0.0.1` or `::1` (or both) listen on the port. Only listening addresses are tested later.
15. The SYSTEM account name is ASCII.

### 2. Account check

The script reads `svc_veeam` through ADSI and checks Administrators membership by SID. It adds the account to Administrators and sets the three flags with `-Apply` or `-CreateServiceAccount`. It never enables, unlocks or resets the account: a disabled, locked out or expired account is reported only and does not block the database change.

### 3. Database audit (every run, no changes)

The script tests whether SYSTEM can log in to PostgreSQL over SSPI as `-U postgres -d <SqlDatabaseName>` on each listening loopback address. When it can, it also reads `pg_stat_activity` and whether the `postgres` role has a password (true or false only, never the hash). It then reports:

- `DbAuth`: `WINDOWS` only when the registry says Windows authentication, the SSPI test passes on every listening address, PostgreSQL loads `pg_hba.conf` and `pg_ident.conf` without errors and `SHOW hba_file`/`ident_file` name the files in the data folder, the first `pg_hba.conf` line that matches the VBR database and user `postgres` is `sspi map=veeam`, and every VBR backend uses `postgres` from a loopback address. `NATIVE` when the registry holds a user name or password. `UNKNOWN` in any other case.
- `PgHba`: `STANDARD` when the active lines are exactly Veeam's six SSPI lines (KB4818).
- `PgIdent`: `STANDARD`, `MISSING_ENTRY` or `EXTRA_ENTRY`.
- `PgPassword`: `NONE`, `SET`, or `UNKNOWN` while SYSTEM cannot log in yet.
- Blockers: password consumers and remote clients (see [Remote clients](#remote-clients-are-a-point-in-time-check)).

### 4. Which change `-Apply` makes

`-Apply` changes the database only when all of these hold. Otherwise it reports the reason and exits 5:

- `svc_veeam` exists and is in Administrators.
- No `PG_PASSWORD_CONSUMER`, `PG_REMOTE_CONSUMER` or `SERVICE_ACCOUNT_UNRESOLVED`.
- `DbAuth` is not `UNKNOWN`.

If everything already matches the standard, it changes nothing and stops no service.

### Path A: VBR already uses Windows authentication (no downtime)

Used when `DbAuth=WINDOWS`, `SqlHostName` is a loopback name and `PostgresUserForWindowsAuth` is fine. SYSTEM can log in to `postgres` before and after the change, so no service is stopped.

1. Create the run folder, back up `pg_hba.conf` and `pg_ident.conf`, record their ACLs (SDDL), write the marker. Stage `PATH_A_WRITING`.
2. Write `pg_ident.conf`, then `pg_hba.conf`, only where they are not standard. Lines that are removed are commented out with `# [VbrStandardise <stamp>]`; nothing is deleted.
3. Test: the SSPI login on every listening address, `pg_hba_file_rules` (and `pg_ident_file_mappings` on PostgreSQL 15 and later) without errors, and `SHOW hba_file`/`ident_file` naming the edited files. If the test fails, both files are restored from the run folder and tested again: exit 40 `PG_SSPI_TEST_FAILED` if SYSTEM can log in again (marker removed), else exit 50 `ROLLBACK_FAILED` (marker stays).
4. Remove the marker. Stage `PATH_A_DONE`.
5. Clear the `postgres` password if it is set (`PG_PASSWORD_NOT_CLEARED`, exit 5, if that fails; VBR still works).

Every file write and restore uses one routine: a temp file in the data folder, swapped in with `[IO.File]::Replace`, then a check that the file exists, its SHA-256 matches and its ACL is unchanged. A run-folder file is never moved or copied into the data folder, because it would bring the run folder's ACL and PostgreSQL could no longer read it.

### Path B: full conversion (short outage)

Used when `DbAuth=NATIVE`, or for `DB_HOST_NOT_LOCAL` or `DB_WINDOWS_ROLE_NOT_POSTGRES`.

1. If `<WorkRoot>\last-failure.json` exists: exit 5 `PATH_B_PREVIOUS_FAILURE` (see [last-failure.json](#last-failurejson)).
2. Idle gate: no `Veeam.Backup.Manager`, `VeeamAgent` or `Veeam*Explorer*` process. Exit 10 `VEEAM_BUSY`, or exit 5 `VEEAM_BUSY_PERSISTENT` if the oldest one has run longer than 6 hours (log backup or CDP).
3. Record the Veeam services and find the stop set (every running service whose name starts with `Veeam`). A running service outside the set that depends on one in it: exit 5 `SERVICE_DEPENDENT_OUTSIDE_SET`.
4. Create the run folder: `pg_hba.conf.before`, `pg_ident.conf.before`, `services-before.json`, `registry-before.json` (old data of every registry value the script may change, or "absent") and `vbr-key.reg` (a `reg.exe export` of the `DatabaseConfigurations\PostgreSql` key, which must not be empty). Write the marker. Stage `PATH_B_CHANGING`. No backup means no change.
5. Idle gate again, then stop the stop set (at most 5 minutes, never `-Force`, startup types unchanged). If a service does not stop: start what this run stopped, remove the marker, exit 10 `SERVICES_WONT_STOP`. Nothing else has changed.
6. Write `pg_ident.conf`, then `pg_hba.conf`.
7. Test as in Path A. A failure runs the rollback.
8. Switch the registry under `HKLM\SOFTWARE\Veeam\Veeam Backup and Replication\DatabaseConfigurations\PostgreSql`: `SqlUserName` and `SqlSecuredPassword` become empty strings, `PostgresUserForWindowsAuth` becomes `postgres` if needed, and `SqlHostName` becomes `127.0.0.1` (or `::1` if only `::1` listens) if it is not a loopback name. `SqlLockInfo` is never changed.
9. Start the services that were running, in dependency order (at most 5 minutes).
10. Wait up to 10 minutes until `VeeamBackupSvc` runs, a new VBR backend appears in `pg_stat_activity` as `postgres` from loopback, and `Svc.VeeamBackup.log` shows no new authentication error. A failure runs the rollback.
11. Stage `VERIFIED`. Remove the marker. From here on the script never rolls back.
12. Clear the `postgres` password (`PG_PASSWORD_NOT_CLEARED`, exit 5, if that fails).
13. List the other roles that have LOGIN and a password in `Detail`. They cannot log in any more.

**Path B rollback:** stop the stop set, restore `pg_ident.conf` and `pg_hba.conf` from the run folder, restore the registry from `registry-before.json` (and, if a value is still wrong, import `vbr-key.reg` and delete values that were absent), start the services that were running. The result is exit 40 only if `VeeamBackupSvc` stays running for 5 minutes and `Svc.VeeamBackup.log` shows no new authentication error; otherwise exit 50 `ROLLBACK_FAILED`. Either way the script writes `last-failure.json`. It removes the marker only on exit 40.

**Unsupported method:** Veeam supports switching the authentication mode only through the DBConfig utility. This script edits the registry directly (decision D4). The pilot (below) proves the switch on a real server.

### Maintenance window

Run `-Apply` in a maintenance window. Path B stops every running Veeam service, including **vPower NFS**. While it is stopped:

- Instant Recovery VMs and published disks that run from vPower NFS lose their disks.
- File-level restores, Veeam Explorer sessions and running jobs stop.

The idle gate catches running jobs, but it cannot see Instant Recovery or published disks. Check those by hand before a Path B run. Pause log backup and CDP jobs first, or the run stops with `VEEAM_BUSY_PERSISTENT`.

## Exit codes

| Code | Name | Meaning | RMM action |
|---|---|---|---|
| 0 | OK | The server matches the standard, or the script fixed every item. | None. |
| 5 | ACTION_NEEDED | AUDIT found drift, or a fix needs a person or a flag. `ActionRequired` says what to do. | Ticket. Follow `ActionRequired`. |
| 10 | RETRY | Another run holds the lock, a job is running, or a service did not stop before any change. | Retry later, automatically. |
| 11 | UNSUPPORTED | The server is outside the scope, or its PostgreSQL setup is not one the script can edit safely. | Exclude the server, or standardise it by hand. |
| 20 | PREFLIGHT | Wrong PowerShell, not elevated, 32-bit host, Constrained Language Mode, VBR or PostgreSQL not found, or the WorkRoot is not safe. | Fix the RMM job or the server, then re-run. |
| 40 | ESCALATE | A change failed. The script restored the server and checked that VBR works. | Escalate. Read the run folder and the transcript before another `-Apply`. |
| 50 | ESCALATE_NOW | A change failed and the restore also failed, or a marker from an unfinished run exists. VBR may be down. | Page an operator now. |

If a run finds more than one issue, the highest exit code wins. `IssueCode` is the first issue with that code. `Detail` lists every issue as `CODE: detail`, joined by ` | `. One exception: if the lock is held, the script exits 10 at once and checks nothing else, so a normal updater run never shows as 50.

## Issue codes

### Preflight

| Code | Exit | Meaning | Action |
|---|---|---|---|
| `CONCURRENT_RUN` | 10 | This script or `Update-VeeamPostgres.ps1` is already running. | Retry later. |
| `WRONG_POWERSHELL` | 20 | Not Windows PowerShell 5.1. | Run `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`. |
| `NOT_ELEVATED` | 20 | Not running as SYSTEM or elevated. | Run the RMM job as SYSTEM. |
| `HOST_32BIT` | 20 | 32-bit PowerShell on 64-bit Windows. | Use the 64-bit `powershell.exe` (`Sysnative` from a 32-bit agent). |
| `CONSTRAINED_LANGUAGE` | 20 | PowerShell runs in Constrained Language Mode. | Allow the script in AppLocker or WDAC for the RMM agent. |
| `WORKROOT_UNSAFE` | 20 | The WorkRoot is not an absolute local path, is a reparse point, or has an untrusted owner or ACL. | Use a folder only SYSTEM and Administrators control, or the default. |
| `MARKER_PRESENT` | 50 | A run of this script or of the updater stopped in the middle of a change. `Detail` names the marker. | Page an operator now. Hold updater jobs. Follow [MARKER_PRESENT: manual recovery](#marker_present-manual-recovery). |
| `DOMAIN_CONTROLLER` | 11 | The server is a domain controller. | Exclude it. |
| `VBR_NOT_FOUND` | 20 | No VBR server is installed. | Exclude the server, or repair VBR. |
| `VBR_DB_NOT_POSTGRES` | 11 | VBR uses Microsoft SQL Server. | Exclude it. |
| `STACKED_VBR_VB365` | 11 | VB365 is installed on the same server. | Exclude it. |
| `REMOTE_DB` | 11 | The configuration database is on another server. | Exclude it. |
| `NO_PG_FOUND` | 20 | No usable PostgreSQL install: none in `HKLM:\SOFTWARE\PostgreSQL\Installations`, an entry without `Version`, `Base Directory` or `Data Directory`, no PostgreSQL service, a service that is not the registry `Service ID` or whose binary is not under `Base Directory`, or no `psql.exe`. `Detail` says which. | Check the PostgreSQL install. |
| `MULTIPLE_PG` | 11 | More than one PostgreSQL install or PostgreSQL service. | Remove the unused install, or standardise by hand. |
| `PG_NOT_RUNNING` | 20 | The PostgreSQL service does not run. | Find out why, start the service, re-run. |
| `PG_INSTANCE_MISMATCH` | 11 | `postmaster.pid` does not name a live `postgres.exe` on the VBR port, or `SqlHostPort` is missing. | Check by hand which instance VBR uses. |
| `PG_NOT_LISTENING` | 20 | Neither `127.0.0.1` nor `::1` listens on the port. | Check `listen_addresses` and the service. |
| `PG_CONF_OVERRIDE` | 11 | `postgresql.conf` or `postgresql.auto.conf` sets `hba_file` or `ident_file`. | Standardise by hand. |
| `PG_HBA_INCLUDE` | 11 | `pg_hba.conf` uses `include`, `include_if_exists`, `include_dir` or `@file`. | Standardise by hand. |
| `PG_IDENT_LOCALISED` | 11 | The SYSTEM account name has non-ASCII characters. | Standardise by hand. |

### Account

| Code | Exit | Meaning | Action |
|---|---|---|---|
| `SVC_ACCOUNT_MISSING` | 5 | `svc_veeam` does not exist. No database change is made. | Set RMM secure variable `VEEAM_SVC_PASSWORD` and re-run with `-CreateServiceAccount`. |
| `SVC_PASSWORD_REQUIRED` | 5 | `-CreateServiceAccount` ran without `VEEAM_SVC_PASSWORD`. Nothing was created. | Set the secure variable for this server and re-run. |
| `SVC_PASSWORD_POLICY` | 5 | Windows rejected the password (password policy). Nothing was created. | Use a password that meets the policy and re-run. |
| `SVC_NAME_IN_USE` | 5 | A local group or other object already uses the name `svc_veeam`. | Rename or remove that object by hand, then re-run. |
| `SVC_NOT_ADMIN` | 5 | `svc_veeam` is not in Administrators. | Re-run with `-Apply`. If it comes back, a group policy removes it. |
| `SVC_FLAGS_DRIFT` | 5 | A flag is wrong: password expires, user can change it, or the account expires. | Re-run with `-Apply`. |
| `SVC_DISABLED` | 5 | The account is disabled. Reported only. | Enable it by hand if people should use it. |
| `SVC_LOCKED_OUT` | 5 | The account is locked out. Reported only. | Unlock it by hand and find the failed logins. |
| `SVC_PASSWORD_EXPIRED` | 5 | The password has expired. Reported only. | Reset it by hand and update the password vault. |

### Database state

| Code | Exit | Meaning | Action |
|---|---|---|---|
| `DB_NATIVE_AUTH` | 5 | VBR logs in to PostgreSQL with a user name and password. | Re-run with `-Apply` in a maintenance window (Path B). |
| `DB_AUTH_UNKNOWN` | 5 | The script cannot prove how VBR logs in. `Detail` says why. No database change. | Check by hand: the registry values, `pg_hba.conf` and `pg_stat_activity`. |
| `DB_HOST_NOT_LOCAL` | 5 | `SqlHostName` is this server's name or address, not a loopback name. | Re-run with `-Apply` in a maintenance window (Path B). |
| `DB_WINDOWS_ROLE_NOT_POSTGRES` | 5 | `PostgresUserForWindowsAuth` is a role other than `postgres`. | Re-run with `-Apply` in a maintenance window (Path B). |
| `PG_HBA_NOT_STANDARD` | 5 | `pg_hba.conf` is not Veeam's six SSPI lines. `Detail` lists the lines for other addresses that `-Apply` comments out. | Check that nothing still needs those lines, then re-run with `-Apply`. |
| `PG_IDENT_NOT_STANDARD` | 5 | The `veeam` map misses a required name or holds an extra one. | Re-run with `-Apply`. |
| `PG_POSTGRES_PASSWORD_SET` | 5 | The `postgres` role still has a password. | Re-run with `-Apply`. |
| `SERVICE_ACCOUNT_UNRESOLVED` | 5 | A Veeam service runs as an account the script cannot map (NetworkService, LocalService, a gMSA or an unresolvable name). No `veeam` line is removed and no database change is made. | Check the account of that service. Map it by hand if it is needed. |

### Blockers

| Code | Exit | Meaning | Action |
|---|---|---|---|
| `PG_PASSWORD_CONSUMER` | 5 | Something still logs in with a password: Enterprise Manager on this server, the Entra ID repository, or a client session as another role (for example `pg_native_admin`). | Move the client to Windows authentication or stop it, then re-run. |
| `PG_REMOTE_CONSUMER` | 5 | A client connects to PostgreSQL from another computer. | Move or stop the remote client, then re-run. |
| `VEEAM_BUSY` | 10 | A Veeam job or Explorer runs. | Retry later. |
| `VEEAM_BUSY_PERSISTENT` | 5 | Veeam work has run for more than 6 hours (log backup or CDP). | Pause log backup or CDP jobs and re-run in a maintenance window. |
| `SERVICE_DEPENDENT_OUTSIDE_SET` | 5 | A running non-Veeam service depends on a Veeam service. | Stop or reconfigure that service, then re-run. |
| `PATH_B_PREVIOUS_FAILURE` | 5 | `last-failure.json` exists from an earlier Path B rollback. | See [last-failure.json](#last-failurejson). |

### Change results

| Code | Exit | Meaning | Action |
|---|---|---|---|
| `SERVICES_WONT_STOP` | 10 | A Veeam service did not stop within 5 minutes. The script started what it stopped; nothing else changed. | Retry later. If it repeats, find out why the service hangs. |
| `PG_SSPI_TEST_FAILED` | 40 | After the write, SYSTEM could not log in or PostgreSQL rejected the files. The script restored them (and, in Path B, the registry and services). | Escalate. Read the transcript and the run folder. |
| `VBR_DB_CONNECT_FAILED` | 40 | After the switch, VBR did not connect to its database within 10 minutes, or a service did not start. The script rolled back. | Escalate. Read `last-failure.json`, the run folder and `Svc.VeeamBackup.log`. |
| `PG_PASSWORD_NOT_CLEARED` | 5 | VBR works with Windows authentication, but the `postgres` password could not be cleared. | Re-run with `-Apply`. |
| `POST_CONVERSION_STEP_FAILED` | 5 | The change was verified and VBR works, but a later step failed (for example removing the marker). Nothing was rolled back. | Read the transcript, then re-run with `-Apply`. |
| `ROLLBACK_FAILED` | 50 | A change failed and the restore or rollback also failed. VBR may be down. The marker stays. | Page an operator now. Follow [MARKER_PRESENT: manual recovery](#marker_present-manual-recovery). |
| `UNHANDLED_ERROR` | 20, 40 | An unexpected error. Exit 20 before any database change. Exit 40 when the script restored the files or rolled back and VBR works. (If that restore fails, the result is 50 `ROLLBACK_FAILED`.) After the change was verified it is reported as `POST_CONVERSION_STEP_FAILED` instead. | Read the transcript. Escalate for 40. |

## RMM output

Every run ends with one block, which RMM can parse:

```
=== RMM SUMMARY ===
Computer=VBR01; Timestamp=2026-10-12T02:00:05+11:00; Mode=AUDIT; VbrVersion=12.3.2.3617; PgMajor=15; SvcAccount=OK; DbAuth=NATIVE; PgHba=NOT_STANDARD; PgIdent=MISSING_ENTRY; PgPassword=UNKNOWN; Stage=UNTOUCHED; Outcome=DB_NATIVE_AUTH; ExitCode=5; IssueCode=DB_NATIVE_AUTH; ActionRequired=Re-run with -Apply in a maintenance window; Detail=DB_NATIVE_AUTH: VBR logs in to PostgreSQL with a user name and password (registry SqlUserName or SqlSecuredPassword is set). | PG_HBA_NOT_STANDARD: The active pg_hba.conf lines are not Veeam's six SSPI lines. | PG_IDENT_NOT_STANDARD: The veeam map in pg_ident.conf is MISSING_ENTRY. Required: SYSTEM@NT AUTHORITY, svc_veeam@VBR01.; LogPath=C:\ProgramData\VeeamStandardise\logs\VbrStandardise_VBR01_20261012-020004-4242.log
RMM ACTION: Re-run with -Apply in a maintenance window
RMM ISSUE: DB_NATIVE_AUTH | DB_NATIVE_AUTH: VBR logs in to PostgreSQL with a user name and password (registry SqlUserName or SqlSecuredPassword is set). | PG_HBA_NOT_STANDARD: The active pg_hba.conf lines are not Veeam's six SSPI lines. | PG_IDENT_NOT_STANDARD: The veeam map in pg_ident.conf is MISSING_ENTRY. Required: SYSTEM@NT AUTHORITY, svc_veeam@VBR01.
===================
```

| Field | Values |
|---|---|
| `SvcAccount` | `OK`, `MISSING`, `NAME_IN_USE`, `NOT_ADMIN`, `FLAGS_DRIFT`, `DISABLED`, `LOCKED_OUT`, `EXPIRED` |
| `DbAuth` | `WINDOWS`, `NATIVE`, `UNKNOWN` |
| `PgHba` | `STANDARD`, `NOT_STANDARD` |
| `PgIdent` | `STANDARD`, `MISSING_ENTRY`, `EXTRA_ENTRY` |
| `PgPassword` | `NONE`, `SET`, `UNKNOWN` |
| `Stage` | `UNTOUCHED`, `PATH_A_WRITING`, `PATH_A_DONE`, `PATH_B_CHANGING`, `VERIFIED` |

`Detail` is shortened to 900 characters. The transcript has the full text. On a successful `-Apply`, `Detail` (and the transcript) also lists the `pg_hba.conf` lines that were commented out and the roles that can no longer log in with a password, after any issues; with no issue, `ExitCode=0` and `IssueCode` stays empty.

## Files on the server

Everything lives under the WorkRoot (default `C:\ProgramData\VeeamStandardise`). Only SYSTEM and Administrators can read it.

| Path | Content |
|---|---|
| `logs\VbrStandardise_<COMPUTER>_<yyyyMMdd-HHmmss>-<PID>.log` | The transcript of each run. |
| `logs\last-result.json` | The summary fields of the last run. |
| `runs\<yyyyMMdd-HHmmss>\` | One folder per run that changed something: `pg_hba.conf.before`, `pg_ident.conf.before`, and for Path B also `services-before.json`, `registry-before.json` and `vbr-key.reg`. |
| `CHANGES-IN-PROGRESS.marker` | Exists only while a change is in progress, or after a run stopped in the middle of one. JSON: `RunDir`, `Path` (A or B), `Stage`, `Time`. |
| `last-failure.json` | Written after every Path B rollback. JSON with the run folder and the reason. |

Logs and run folders older than 30 days are deleted at the start of each run. This clean-up never deletes the marker or `last-failure.json`, and it does not run while either of them exists.

`registry-before.json` and `vbr-key.reg` hold the old `SqlSecuredPassword` value, which Veeam stores encrypted. Treat the run folders as sensitive. The script never reads or saves the `postgres` password hash.

## MARKER_PRESENT: manual recovery

A marker means a run stopped between its first change and its safe end: RMM killed it (timeout), the server rebooted, or a restore failed (`ROLLBACK_FAILED`). Every run exits 50 until a person clears it. VBR may be down.

1. **Hold jobs.** Pause this script's `-Apply` job and every `Update-VeeamPostgres.ps1` job for the server.
2. **Read the marker.** `Detail` names the file. If it is the updater's marker (`C:\ProgramData\VeeamPgUpdate\CHANGES-IN-PROGRESS.marker` or `C:\temp\VeeamPgUpdate\CHANGES-IN-PROGRESS.marker`), follow the updater's README instead. For this script's marker, open it: `Path` (A or B), `Stage` and `RunDir`. Read the transcript of that run in `logs\` to see the last step that ran.
3. **Find the live files.** The data folder is `Data Directory` under `HKLM:\SOFTWARE\PostgreSQL\Installations\<id>`. Compare the live files with the backups:

   ```powershell
   $run  = 'C:\ProgramData\VeeamStandardise\runs\<stamp>'
   $data = 'C:\Program Files\PostgreSQL\15\data'
   foreach ($name in 'pg_hba.conf', 'pg_ident.conf') {
       '{0}: live {1} / before {2}' -f $name, (Get-FileHash "$data\$name").Hash, (Get-FileHash "$run\$name.before").Hash
   }
   ```

4. **Path B only: compare the registry.** Compare `Get-ItemProperty 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication\DatabaseConfigurations\PostgreSql'` with `registry-before.json` for `SqlUserName`, `SqlSecuredPassword`, `PostgresUserForWindowsAuth` and `SqlHostName`. Do not paste the `SqlSecuredPassword` data into tickets.
5. **Decide: keep or restore.**
   - **Keep** (Path B only) if the registry is already switched, both files are standard, `VeeamBackupSvc` runs, the VBR console connects, and `C:\ProgramData\Veeam\Backup\Svc.VeeamBackup.log` shows no new `SSPI authentication failed`, `no match in usermap`, `password authentication failed`, `no pg_hba.conf entry`, `28000` or `28P01`. Then go to step 7. A later `-Apply` takes Path A and clears the `postgres` password.
   - **Restore** in every other case, and always for Path A.
6. **Restore.**
   - Stop the Veeam services in `StopSet` of `services-before.json` (Path B) if they run.
   - Put the old file contents back **into the existing files**, so the files keep their ACL. Never move or copy a `.before` file into the data folder: it would bring the run folder's ACL, and PostgreSQL could not read it.

     ```powershell
     foreach ($name in 'pg_ident.conf', 'pg_hba.conf') {
         $sddl = (Get-Acl "$data\$name").Sddl
         [IO.File]::WriteAllBytes("$data\$name", [IO.File]::ReadAllBytes("$run\$name.before"))
         if ((Get-Acl "$data\$name").Sddl -ne $sddl) { "ACL CHANGED on $name - fix it before you go on" }
     }
     ```

   - Path B: put each registry value back as `registry-before.json` records it (a String value with its old data, or delete it if it was absent). Or run `reg.exe import "$run\vbr-key.reg"` and then delete the values that `registry-before.json` lists as absent. Check every value again.
   - Start the services in `StopSet` of `services-before.json`: `Start-Service -Name <name>` for each one.
7. **Check VBR.** `VeeamBackupSvc` stays running for 5 minutes, the console connects, and `Svc.VeeamBackup.log` shows no new authentication error.
8. **Delete the marker:** `Remove-Item 'C:\ProgramData\VeeamStandardise\CHANGES-IN-PROGRESS.marker'`.
9. **Fix the cause** before the next `-Apply`, for example a longer RMM timeout. For a Path B failure you do not understand yet, create `last-failure.json` by hand (any JSON, for example `{"Reason":"manual hold"}`) so that a scheduled `-Apply` cannot start Path B again.
10. **Run an AUDIT** (no flags) and check the summary. Then release the held jobs.

## last-failure.json

After every Path B rollback, the script writes `<WorkRoot>\last-failure.json` with the run folder and the reason. While it exists, Path B does not run: AUDIT and `-Apply` report `PATH_B_PREVIOUS_FAILURE` (exit 5), so a scheduled `-Apply` cannot cause the same outage again and again. Path A still runs.

To clear it:

1. Read the reason and open the run folder it names. Read that run's transcript in `logs\` and `C:\ProgramData\Veeam\Backup\Svc.VeeamBackup.log` from the time of the run.
2. Fix the cause (for example a Veeam service that runs as an unmapped account, or a client that still needs a password).
3. Delete `last-failure.json`.
4. Re-run `-Apply` in a maintenance window.

## Remote clients are a point-in-time check

Before any database change, the script looks for clients that would lose access: client sessions in `pg_stat_activity` that use another role or come from another computer (when SYSTEM can log in), or established TCP connections to the PostgreSQL port from another address (when it cannot). It also checks the Enterprise Manager and Entra ID repository settings in the registry.

This is a check at one moment. A client that connects only now and then, for example a nightly report, a monitoring tool or a remote Enterprise Manager, can be missed. `-Apply` then comments out the `pg_hba.conf` lines for other addresses and removes the `postgres` password, and that client fails at its next connection. Before `-Apply`, read the lines that `PG_HBA_NOT_STANDARD` lists in `Detail` and find out who uses them. Path A on a server that has `pg_native_admin` removes that role's login too.

## Testing

Run the tests from an elevated prompt in the project folder, on both editions:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1
pwsh.exe       -NoProfile -ExecutionPolicy Bypass -File .\Test-VbrStandardise.ps1
```

A pass ends with `RESULT: <n> passed, 0 failed` and exit code 0. `SKIP` lines are not failures.

- The test file parses `Invoke-VbrStandardise.ps1`, loads its functions and never runs the main body. It does not use Pester.
- Every function that would change the system is replaced by a mock in a child scope. The tests create only temp folders (`%TEMP%\vbrstd-*`) and throwaway `HKCU:` keys, and remove them at the end. They never create a local user, never change a service and never write to `HKLM:`.
- Static checks enforce the rules: no `Stop-Service -Force`, no `Stop-Process`, no `Get-LocalGroupMember`, no `Read-Host`, no `Out-File`, no `Set-Content -Encoding UTF8`, no `ConvertTo-SecureString` with a literal, no `Invoke-Expression`; the parameter list; the order of the main body.
- Three child-process runs use the real script: an AUDIT under `powershell.exe` on a machine without VBR must exit 20 `VBR_NOT_FOUND` with a valid summary, a run under `pwsh.exe` must exit 20 `WRONG_POWERSHELL`, and a run from a session switched to Constrained Language Mode must exit 20 `CONSTRAINED_LANGUAGE` and write nothing. The first two are skipped when the machine has a VBR server, is a domain controller, is not elevated, or has no `pwsh.exe`; the third always runs.

## Pilot order

1. **AUDIT** on a few servers. Review the summaries, especially `DbAuth`, the `pg_hba.conf` lines in `Detail`, and any blocker.
2. **`-Apply` on VBR-PILOT01.** It should take Path A: replace the split-by-role `pg_hba.conf`, clean `pg_ident.conf` and clear the `postgres` password, with no downtime. After this, `pg_native_admin` can no longer log in. If a script or tool uses `pg_native_admin` at that moment, the run stops with `PG_PASSWORD_CONSUMER`.
3. **`-Apply` on one server that still uses a password**, in a maintenance window, with an RMM timeout of 45 minutes or more. It takes Path B. This run proves that VBR starts after the direct registry switch without a new `SqlLockInfo`.
4. Then the rest of the fleet: AUDIT first, `-Apply` in maintenance windows.
````

- [ ] **Step 2: Check that the README names every exit code and every issue code**

Run this from the project folder:

```powershell
$readme = Get-Content -LiteralPath .\README.md -Raw
$exitCodes = [ordered]@{ '0' = 'OK'; '5' = 'ACTION_NEEDED'; '10' = 'RETRY'; '11' = 'UNSUPPORTED'; '20' = 'PREFLIGHT'; '40' = 'ESCALATE'; '50' = 'ESCALATE_NOW' }
$issueCodes = @(
    'CONCURRENT_RUN', 'WRONG_POWERSHELL', 'NOT_ELEVATED', 'HOST_32BIT', 'CONSTRAINED_LANGUAGE', 'WORKROOT_UNSAFE', 'MARKER_PRESENT',
    'DOMAIN_CONTROLLER', 'VBR_NOT_FOUND', 'VBR_DB_NOT_POSTGRES', 'STACKED_VBR_VB365', 'REMOTE_DB', 'NO_PG_FOUND', 'MULTIPLE_PG',
    'PG_NOT_RUNNING', 'PG_INSTANCE_MISMATCH', 'PG_NOT_LISTENING', 'PG_CONF_OVERRIDE', 'PG_HBA_INCLUDE', 'PG_IDENT_LOCALISED',
    'SVC_ACCOUNT_MISSING', 'SVC_PASSWORD_REQUIRED', 'SVC_PASSWORD_POLICY', 'SVC_NAME_IN_USE', 'SVC_NOT_ADMIN', 'SVC_FLAGS_DRIFT',
    'SVC_DISABLED', 'SVC_LOCKED_OUT', 'SVC_PASSWORD_EXPIRED',
    'DB_NATIVE_AUTH', 'DB_AUTH_UNKNOWN', 'DB_HOST_NOT_LOCAL', 'DB_WINDOWS_ROLE_NOT_POSTGRES', 'PG_HBA_NOT_STANDARD',
    'PG_IDENT_NOT_STANDARD', 'PG_POSTGRES_PASSWORD_SET', 'SERVICE_ACCOUNT_UNRESOLVED',
    'PG_PASSWORD_CONSUMER', 'PG_REMOTE_CONSUMER', 'VEEAM_BUSY', 'VEEAM_BUSY_PERSISTENT', 'SERVICE_DEPENDENT_OUTSIDE_SET', 'PATH_B_PREVIOUS_FAILURE',
    'SERVICES_WONT_STOP', 'PG_SSPI_TEST_FAILED', 'VBR_DB_CONNECT_FAILED', 'PG_PASSWORD_NOT_CLEARED', 'POST_CONVERSION_STEP_FAILED',
    'ROLLBACK_FAILED', 'UNHANDLED_ERROR'
)
$missing = @()
foreach ($code in $exitCodes.Keys) {
    if ($readme -notmatch ('\|\s*{0}\s*\|\s*{1}\s*\|' -f $code, $exitCodes[$code])) { $missing += "exit $code $($exitCodes[$code])" }
}
foreach ($code in $issueCodes) {
    if ($readme -notmatch ('\|\s*`{0}`\s*\|\s*\d' -f $code)) { $missing += $code }
}
foreach ($phrase in @('VEEAM_SVC_PASSWORD', '45 minutes', 'vPower NFS', 'last-failure.json', 'point-in-time', 'Pilot order')) {
    if ($readme.IndexOf($phrase, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $missing += "phrase '$phrase'" }
}
if ($missing.Count -eq 0) { "README check: all $($exitCodes.Count) exit codes and $($issueCodes.Count) issue codes present" }
else { 'README check: missing ' + ($missing -join ', ') }
```

Expected output: `README check: all 7 exit codes and 50 issue codes present`. Any other output names what is missing; add it to the tables and run the check again.

- [ ] **Step 3: Commit**

```powershell
git add README.md
git commit -m "Add README for RMM setup, codes and manual recovery" -m "Documents how to run the script from RMM (SYSTEM, 64-bit Windows PowerShell 5.1, secure variable VEEAM_SVC_PASSWORD, 45-minute timeout), the flags, every exit and issue code with its action, what Path A and Path B change, the vPower NFS maintenance window, the MARKER_PRESENT recovery steps, last-failure.json, the point-in-time limit of the remote-client check, the tests and the pilot order." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

