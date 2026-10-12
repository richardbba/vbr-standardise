# VBR Standardise: svc_veeam account and PostgreSQL Windows authentication

Date: 2026-10-12. Status: design approved by the user. Revision 2 adds the fixes from an adversarial review (27 confirmed findings). Revision 3 adds the registry snapshots from VBR-PILOT01 (Windows auth) and VBR-PILOT02 (native auth). No open items.

## 1. Goal

`Invoke-VbrStandardise.ps1` runs from RMM on Windows Veeam Backup & Replication (VBR) servers. It makes each server match this standard:

1. A local account `svc_veeam` exists. It is a member of local Administrators. Its password never expires, the user cannot change it, and the account never expires.
2. The VBR configuration database (PostgreSQL) uses Windows authentication (SSPI). No password login to PostgreSQL is possible.
3. `pg_ident.conf` maps only `SYSTEM`, `svc_veeam` and any account that a Veeam service runs as, to the `postgres` role. `svc_veeam` is the account that people use for Veeam upgrades, Veeam maintenance and PostgreSQL maintenance.

The script is the first part of a wider standardisation script. Write each check as its own function, so that a new check can be added later without changes to the existing checks.

## 2. Decisions (made by the user)

| # | Decision |
|---|---|
| D1 | The script runs from RMM only, as SYSTEM, with no prompts. |
| D2 | If `svc_veeam` does not exist, the script ends with a soft error and a message. A re-run with `-CreateServiceAccount` creates the account. |
| D3 | The `svc_veeam` password comes from an RMM secure variable, which RMM gives to the script as the environment variable `VEEAM_SVC_PASSWORD`. There is no password parameter. |
| D4 | The script switches VBR to Windows authentication by editing the registry directly. Veeam does not support this method. It does not use the DBConfig GUI. |
| D5 | No native (password) PostgreSQL logins. There is no `pg_native_admin` role. `pg_hba.conf` becomes Veeam's default SSPI layout. The `postgres` role password is removed. |
| D6 | The `veeam` map in `pg_ident.conf` holds only `SYSTEM` and `svc_veeam`. The script removes other accounts, for example `Administrator@HOST` or the account that installed Veeam. Exception: the account of any Veeam service that does not run as LocalSystem (section 7.3). |
| D7 | The Veeam services keep running as LocalSystem. `svc_veeam` does not run any service. |
| D8 | The script is a new standalone script. It copies helper functions from `..\Veeam Postgres Updater\Update-VeeamPostgres.ps1` and does not change that script. |

## 3. Out of scope

- VBR servers that use Microsoft SQL Server for the configuration database.
- A configuration database on a different server.
- VBR and Veeam Backup for Microsoft 365 (VB365) on the same server. VB365 shares the PostgreSQL instance and needs remote SSPI lines for its proxies. The script exits 11 `STACKED_VBR_VB365`, the same as the updater.
- VBR on Linux or the Veeam Software Appliance.
- Domain controllers.
- Non-English Windows where the SYSTEM account name has non-ASCII characters (for example `NT-AUTORITÄT`). The script exits 11 `PG_IDENT_LOCALISED`.
- Changing the account that the Veeam services run as.
- PostgreSQL upgrades. `Update-VeeamPostgres.ps1` does those.
- A recovery mode. If a run stops in the middle of a change, a person recovers the server with the steps in the README.

## 4. Files

| File | Purpose |
|---|---|
| `Invoke-VbrStandardise.ps1` | The script. It is one self-contained file, so RMM can upload a single file. |
| `Test-VbrStandardise.ps1` | Tests. It uses the same custom harness style as `Test-Helpers.ps1`: it parses the script, loads only the named functions, and does not run the main body. It does not use Pester. |
| `README.md` | How to run the script from RMM, the RMM timeout, the exit codes, the issue codes and the manual recovery steps. |

## 5. Runtime and conventions (copied from the updater)

- **Windows PowerShell 5.1 (Desktop edition), 64-bit, only.** The script refuses PowerShell 7 (section 7.1). Under PowerShell 7 the LocalAccounts cmdlets run through a compatibility session, so their typed exceptions arrive as `RemoteException`, and `[Text.Encoding]::Default` changes from ANSI to UTF-8. The test file must still load its functions under PowerShell 7.
- `Set-StrictMode -Version 2.0`, `$ErrorActionPreference = 'Stop'`, `[CmdletBinding()]`. The script does not use the Veeam PowerShell module.
- Help block with `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` and `.NOTES`. The exit code table goes in `.NOTES`.
- Built-in settings block at the top, under a banner. Settings and defaults:

| Setting | Default |
|---|---|
| `ServiceAccountName` | `svc_veeam` |
| `ServiceAccountDescription` | `Veeam maintenance account (PostgreSQL SSPI map)` (48 characters or fewer) |
| `PasswordEnvVar` | `VEEAM_SVC_PASSWORD` |
| `ServiceStopTimeoutSec` | 300 (for the whole stop, and again for the whole start) |
| `VbrConnectTimeoutSec` | 600 |
| `RollbackSettleSec` | 300 |
| `BusyPersistentHours` | 6 |
| `RetentionDays` | 30 |

- Worst-case run time is about 30 minutes: stop 5, connect wait 10, rollback stop 5, rollback settle 5, plus checks. The README says the RMM script timeout must be 45 minutes or more. If RMM kills the process, the trap does not run, and the marker stays (section 7.6).
- `Write-Log -Message -Level` (`INFO`, `WARN`, `ERROR`, `OK`, `STEP`) and a transcript at `<WorkRoot>\logs\VbrStandardise_<COMPUTERNAME>_<stamp>-<PID>.log`. Start the transcript only after the WorkRoot ACL check passes.
- `<WorkRoot>` = `C:\ProgramData\VeeamStandardise`. Each run that makes a change has a run folder `<WorkRoot>\runs\<stamp>\`. Only SYSTEM and Administrators can read the WorkRoot.
- `$script:Report`, `Complete-Run`, the `=== RMM SUMMARY ===` block, `last-result.json` and a `trap` work the same way as in the updater. The trap's action depends on the stage (section 7.6).
- `Invoke-Native` runs every external program. Errors come back as values. They are not thrown. Never log the arguments of a call that carries a secret.
- Single instance: the script takes the `Global\VeeamPgUpdate` mutex, which the updater also uses, so the two scripts cannot run at the same time.
- The updater does not know about this script's marker (D8). The README says: hold updater jobs on any server that reports `MARKER_PRESENT` from this script.

## 6. Parameters, modes and codes

### 6.1 Parameters

| Parameter | Effect |
|---|---|
| (none) | AUDIT. The script reads and reports. It changes nothing. |
| `-Apply` | APPLY. The script fixes every item except a missing account. |
| `-CreateServiceAccount` | The script creates `svc_veeam` if it is missing. It can run alone or together with `-Apply`. Alone, it creates the account and then audits the rest. |
| `-WorkRoot` | Changes the work folder. The default is `C:\ProgramData\VeeamStandardise`. |

### 6.2 Exit codes (the same numbers and names as the updater)

| Code | Name | Meaning |
|---|---|---|
| 0 | OK | The server matches the standard, or the script fixed every item. |
| 5 | ACTION_NEEDED | Soft error. AUDIT found drift, or a fix needs a person or a flag. `ActionRequired` says what to do. |
| 10 | RETRY | Another run holds the lock, a job is running, or a service did not stop before any change. Try again later. |
| 11 | UNSUPPORTED | The server is outside the scope in section 3, or its PostgreSQL setup is not one the script can edit safely. |
| 20 | PREFLIGHT | Wrong PowerShell, not elevated, 32-bit host, Constrained Language Mode, VBR or PostgreSQL not found, or the WorkRoot is not safe. |
| 40 | ESCALATE | A change failed. The script restored the server and checked that VBR works. |
| 50 | ESCALATE_NOW | A change failed and the restore also failed, or a marker from an unfinished run exists. VBR may be down. |

If a run finds more than one issue, the highest exit code wins. `IssueCode` is the issue with that code. `Detail` lists every issue. One exception: if the mutex is held, the script exits 10 at once and checks nothing else, so a normal updater run never shows as 50.

### 6.3 Issue codes

| Area | Codes |
|---|---|
| Preflight | `CONCURRENT_RUN`, `WRONG_POWERSHELL`, `NOT_ELEVATED`, `HOST_32BIT`, `CONSTRAINED_LANGUAGE`, `WORKROOT_UNSAFE`, `MARKER_PRESENT`, `DOMAIN_CONTROLLER`, `VBR_NOT_FOUND`, `VBR_DB_NOT_POSTGRES`, `STACKED_VBR_VB365`, `REMOTE_DB`, `NO_PG_FOUND`, `MULTIPLE_PG`, `PG_NOT_RUNNING`, `PG_INSTANCE_MISMATCH`, `PG_NOT_LISTENING`, `PG_CONF_OVERRIDE`, `PG_HBA_INCLUDE`, `PG_IDENT_LOCALISED` |
| Account | `SVC_ACCOUNT_MISSING`, `SVC_PASSWORD_REQUIRED`, `SVC_PASSWORD_POLICY`, `SVC_NAME_IN_USE`, `SVC_NOT_ADMIN`, `SVC_FLAGS_DRIFT`, `SVC_DISABLED`, `SVC_LOCKED_OUT`, `SVC_PASSWORD_EXPIRED` |
| Database state | `DB_NATIVE_AUTH`, `DB_AUTH_UNKNOWN`, `DB_HOST_NOT_LOCAL`, `DB_WINDOWS_ROLE_NOT_POSTGRES`, `PG_HBA_NOT_STANDARD`, `PG_IDENT_NOT_STANDARD`, `PG_POSTGRES_PASSWORD_SET`, `SERVICE_ACCOUNT_UNRESOLVED` |
| Blockers | `PG_PASSWORD_CONSUMER`, `PG_REMOTE_CONSUMER`, `VEEAM_BUSY`, `VEEAM_BUSY_PERSISTENT`, `SERVICE_DEPENDENT_OUTSIDE_SET`, `PATH_B_PREVIOUS_FAILURE` |
| Change results | `SERVICES_WONT_STOP`, `PG_SSPI_TEST_FAILED`, `VBR_DB_CONNECT_FAILED`, `PG_PASSWORD_NOT_CLEARED`, `POST_CONVERSION_STEP_FAILED`, `ROLLBACK_FAILED`, `UNHANDLED_ERROR` |

### 6.4 RMM summary fields

`Computer; Timestamp; Mode; VbrVersion; PgMajor; SvcAccount; DbAuth; PgHba; PgIdent; PgPassword; Stage; Outcome; ExitCode; IssueCode; ActionRequired; Detail; LogPath`

- `SvcAccount` = `OK`, `MISSING`, `NAME_IN_USE`, `NOT_ADMIN`, `DISABLED`, `LOCKED_OUT`, `EXPIRED` or `FLAGS_DRIFT`.
- `DbAuth` = `WINDOWS`, `NATIVE` or `UNKNOWN` (section 7.4).
- `PgHba` = `STANDARD` or `NOT_STANDARD`.
- `PgIdent` = `STANDARD`, `MISSING_ENTRY` or `EXTRA_ENTRY`.
- `PgPassword` = `NONE`, `SET` or `UNKNOWN`. It is `UNKNOWN` when SYSTEM cannot connect over SSPI yet.

## 7. Behaviour

### 7.1 Preflight (all modes, no changes)

Run in this order. The first failure ends the run, except where it says "drift".

0. Constrained Language Mode is checked before everything else, because in that mode the script cannot even create the mutex or its report objects. The script prints a full summary with `Write-Host` only, writes nothing, and exits 20 `CONSTRAINED_LANGUAGE`.
1. Take the `Global\VeeamPgUpdate` mutex. If another process holds it: exit 10 `CONCURRENT_RUN`. Check nothing else.
2. `$PSVersionTable.PSEdition -eq 'Desktop'`. Otherwise exit 20 `WRONG_POWERSHELL`. `ActionRequired`: "Run %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe".
3. Elevated, 64-bit process, FullLanguage mode. Otherwise exit 20 (`NOT_ELEVATED`, `HOST_32BIT`, `CONSTRAINED_LANGUAGE`).
4. WorkRoot passes the ACL and trust checks (copy the updater's). Otherwise exit 20 `WORKROOT_UNSAFE`.
5. Markers. Any of these files exists: exit 50 `MARKER_PRESENT`, with the path in `Detail`.
   - This script's `<WorkRoot>\CHANGES-IN-PROGRESS.marker`.
   - The updater's `C:\ProgramData\VeeamPgUpdate\CHANGES-IN-PROGRESS.marker`.
   - The updater's legacy `C:\temp\VeeamPgUpdate\CHANGES-IN-PROGRESS.marker`. Use the updater's trusted-owner and no-reparse-point test (`Get-TrustedLegacyRecoveryMarker`).
6. Not a domain controller (`Win32_OperatingSystem.ProductType -eq 2`). Otherwise exit 11 `DOMAIN_CONTROLLER`.
7. VBR server installed. Otherwise exit 20 `VBR_NOT_FOUND`. `DatabaseConfigurations\SqlActiveConfiguration` = `PostgreSql`. Otherwise exit 11 `VBR_DB_NOT_POSTGRES`.
8. VB365 not installed: no `Veeam.Archiver.Service` service and no `C:\Program Files\Veeam\Backup365\Veeam.Archiver.Service.exe`. Otherwise exit 11 `STACKED_VBR_VB365`. Copy the updater's detection.
9. `DatabaseConfigurations\PostgreSql\SqlHostName` is this server: `localhost`, `127.0.0.1`, `::1`, the computer name, its FQDN, or one of its own IP addresses. Otherwise exit 11 `REMOTE_DB`. Any value other than `localhost`, `127.0.0.1` or `::1` is drift `DB_HOST_NOT_LOCAL`.
10. `DatabaseConfigurations\PostgreSql\PostgresUserForWindowsAuth` is missing, empty or `postgres`. Any other value is drift `DB_WINDOWS_ROLE_NOT_POSTGRES`.
11. Exactly one PostgreSQL install in `HKLM:\SOFTWARE\PostgreSQL\Installations`. Its service exists and runs, and the service binary is under its `Base Directory`. Copy the updater's discovery code. Otherwise exit 20 `NO_PG_FOUND` or `PG_NOT_RUNNING`, or exit 11 `MULTIPLE_PG`.
12. `postmaster.pid` in the registry `Data Directory` names a live `postgres.exe` process, and its port equals `SqlHostPort`. Otherwise exit 11 `PG_INSTANCE_MISMATCH`. This proves the data directory is the live one without SQL.
13. `postgresql.conf` and `postgresql.auto.conf` do not set `hba_file` or `ident_file`. Otherwise exit 11 `PG_CONF_OVERRIDE`. `pg_hba.conf` has no `include`, `include_if_exists`, `include_dir` or `@file`. Otherwise exit 11 `PG_HBA_INCLUDE`.
14. Find which of `127.0.0.1` and `::1` listen on the port (`Get-NetTCPConnection -State Listen -LocalPort <port>`; a listener on `0.0.0.0` or `::` counts for that family). Record the list. If neither listens: exit 20 `PG_NOT_LISTENING`. Section 7.9 tests only these addresses.
15. Translate `S-1-5-18`. If the name has non-ASCII characters: exit 11 `PG_IDENT_LOCALISED`.

### 7.2 Account check and fix

The script reads the account through ADSI (`WinNT://`). It checks Administrators membership by SID (`S-1-5-32-544`) through ADSI. It does not use `Get-LocalGroupMember`, because that fails on orphaned SIDs. It creates and changes the account with the LocalAccounts cmdlets (`New-LocalUser`, `Set-LocalUser`, `Add-LocalGroupMember`), with the ADSI fallback from the research notes if the module is not present.

| State | AUDIT | `-Apply` | `-CreateServiceAccount` |
|---|---|---|---|
| Missing | `SVC_ACCOUNT_MISSING` (exit 5) | `SVC_ACCOUNT_MISSING` (exit 5). The script makes no database change. `ActionRequired`: "Set RMM secure variable VEEAM_SVC_PASSWORD and re-run with -CreateServiceAccount". | Creates the account and adds it to Administrators, with the three flags set. If `VEEAM_SVC_PASSWORD` is empty: `SVC_PASSWORD_REQUIRED` (exit 5), and nothing is created. |
| Name used by a local group | `SVC_NAME_IN_USE` (exit 5) | exit 5 | exit 5 |
| Not in Administrators | `SVC_NOT_ADMIN` (exit 5) | Adds it to Administrators. | Adds it to Administrators. |
| Flag drift | `SVC_FLAGS_DRIFT` (exit 5) | Sets the three flags. | Sets the three flags. |
| Disabled, locked out, or password expired | Report only (exit 5) | Report only (exit 5). The script never enables, unlocks or resets the account. This does not block the database change. | Report only. |

The three flags:
- Password never expires: UserFlags bit `0x10000`.
- User cannot change password: UserFlags bit `0x40`.
- Account never expires: this is not a UserFlags bit. Check `$u.Properties.Contains('AccountExpirationDate')`. Absent means it never expires. Never read the property directly, because it throws under StrictMode when it is absent. Set it with `Set-LocalUser -AccountNeverExpires`.

Password handling:
- Read `VEEAM_SVC_PASSWORD` once, convert it to a SecureString, and remove the variable from the process environment at once.
- Never write the password to the log, the transcript, the summary or a file.
- `New-LocalUser` throws `InvalidPasswordException` if the password does not meet the Windows password policy, and creates nothing. Report `SVC_PASSWORD_POLICY` (exit 5). `NameInUseException` gives `SVC_NAME_IN_USE`. Match by exception type name.
- Never reset the password of an account that already exists.
- After any change, read the account again and check every item by SID.

### 7.3 Target state

**`pg_hba.conf`** is Veeam's default SSPI layout (KB4818):

```
local   all             all                                     sspi map=veeam
host    all             all             127.0.0.1/32            sspi map=veeam
host    all             all             ::1/128                 sspi map=veeam
local   replication     all                                     sspi map=veeam
host    replication     all             127.0.0.1/32            sspi map=veeam
host    replication     all             ::1/128                 sspi map=veeam
```

`PgHba` = `STANDARD` when the active (not commented) lines are exactly these six lines, compared by field and in order. Spacing and comments are ignored.

**The `veeam` map in `pg_ident.conf`:**

```
veeam   "SYSTEM@NT AUTHORITY"       postgres
veeam   "svc_veeam@<NETBIOSNAME>"   postgres
veeam   "<service account lines>"   postgres
```

- Build each name from a SID with `SecurityIdentifier.Translate([NTAccount])`, in the form `name@domain`. SYSTEM is `S-1-5-18`. For `svc_veeam`, use the account's own SID.
- If the translated SYSTEM name is ASCII but differs from `SYSTEM@NT AUTHORITY` (for example `SISTEMA@AUTORIDADE NT`), it is also a required line. A non-ASCII SYSTEM name stops the run in preflight (step 15).
- If a name that must be added is not printable ASCII, the script stops before any backup, marker or service stop (exit 20 `UNHANDLED_ERROR`, nothing changed). AUDIT does not report this case in advance.
- Service account lines: for each service whose name starts with `Veeam` and whose `StartName` is not LocalSystem (`LocalSystem` or `NT AUTHORITY\SYSTEM`):
  - Turn `.\x` into `<COMPUTERNAME>\x`. Translate `DOMAIN\x` or a UPN to a SID, then translate the SID back to an NTAccount, and form `name@domain`.
  - Keep that line if it exists, and add it if it is missing.
  - If any StartName cannot be resolved, or is NetworkService, LocalService or a gMSA (`x$`): report `SERVICE_ACCOUNT_UNRESOLVED` with the StartName in `Detail`. The script then removes no `veeam` map line and makes no database change in that run (exit 5).
- Lines in other maps (not `veeam`) stay as they are.

`PgIdent` = `STANDARD` when the `veeam` map holds exactly the required lines. Names compare case-insensitively, because PostgreSQL compares literal SSPI names case-insensitively.

### 7.4 Live state

When SYSTEM can log in over SSPI, the script reads more. The SSPI baseline is the test in section 7.9, run before any change.

- `DbAuth`:
  - `NATIVE`: the registry values (section 9) say native authentication.
  - `WINDOWS`: the registry values say Windows authentication, and all of these are true:
    - the SSPI baseline passes on every listening loopback address, as `-U postgres -d <SqlDatabaseName>`, and the config checks of section 7.9 pass;
    - in `pg_hba_file_rules`, the first line that matches the VBR database, user `postgres` and each listening address uses `sspi` with `map=veeam`;
    - every VBR backend in `pg_stat_activity` uses `usename = postgres` and a loopback `client_addr`.
  - `UNKNOWN`: any other case. Report `DB_AUTH_UNKNOWN` (exit 5). The script makes no database change, and a person checks the server.
- `PgPassword`: `SELECT rolpassword IS NOT NULL FROM pg_authid WHERE rolname = 'postgres'`. Read only the boolean, never the hash. `UNKNOWN` without SSPI.

### 7.5 Blockers (checked before any database change, and reported in AUDIT)

Each blocker gives exit 5, and the script makes no database change.

- `PG_PASSWORD_CONSUMER`:
  - Enterprise Manager on this server: `HKLM:\SOFTWARE\Veeam\Veeam Backup Reporting\DatabaseConfigurations` points to this host and port and holds a password value.
  - Entra ID repository: the VBR root key has a non-empty `EntraIdSqlPassword` for this host and port.
  - With SSPI: a client backend in `pg_stat_activity` (`backend_type = 'client backend'`, `pid <> pg_backend_pid()`) whose `usename` is not `postgres`, for example a script that uses `pg_native_admin`.
- `PG_REMOTE_CONSUMER`:
  - With SSPI: a client backend whose `client_addr` is not NULL, `127.0.0.1` or `::1`. Exception: when `SqlHostName` is a local non-loopback name (`DB_HOST_NOT_LOCAL`), a client from one of this server's own IP addresses is VBR itself, not a remote consumer. Otherwise Path B could never fix that drift.
  - Without SSPI: a `Get-NetTCPConnection -State Established -LocalPort <port>` entry with a remote address that is not loopback.
  - `ActionRequired`: "Move or stop the remote client, then re-run".
- Active `pg_hba.conf` lines for other addresses (LAN lines, `samehost`, `samenet`, host names) are not blockers on their own. If no remote client uses them at the time of the run, the script comments them out (D5) and lists them in `Detail`. The README says this is a point-in-time check: a client that connects only now and then can be missed.

### 7.6 Apply flow

Both paths need all of these. Otherwise the script makes no database change (exit 5):
- `svc_veeam` exists and is in Administrators. A disabled, locked or expired account does not block. It is reported only.
- No blocker from section 7.5.
- `DbAuth` is not `UNKNOWN`. No `SERVICE_ACCOUNT_UNRESOLVED`.

If every item is compliant, the script changes nothing and stops no service.

**Stages.** The script keeps a `Stage` value. The trap reads it to decide what to do on an unexpected error.

| Stage | Trap action |
|---|---|
| `UNTOUCHED` | No change was made. Exit 20 `UNHANDLED_ERROR`. |
| `PATH_A_WRITING` | Restore both files (section 7.8), run section 7.9 again. If it passes, remove the marker and exit 40. If it fails, exit 50. |
| `PATH_A_DONE`, `VERIFIED` | Never roll back. VBR works. Exit 5 `POST_CONVERSION_STEP_FAILED`. Remove the marker. |
| `PATH_B_CHANGING` | Run the Path B rollback. |

**Path A: VBR already uses Windows authentication.** Use this path when `DbAuth` = `WINDOWS`, `SqlHostName` is a loopback name and `PostgresUserForWindowsAuth` is OK. There is no downtime, because the SYSTEM login to `postgres` works before and after the change.

1. Create the run folder. Back up `pg_hba.conf` and `pg_ident.conf`. Record the SDDL of both files. Write the marker. Stage = `PATH_A_WRITING`.
2. Write the files that are not standard (section 7.8).
3. Test (section 7.9). If the test fails: restore both files, test again, remove the marker if the second test passes, and exit 40. If the second test fails, exit 50.
4. Remove the marker. Stage = `PATH_A_DONE`.
5. If `PgPassword` = `SET`, clear it (section 7.10).

**Path B: full conversion.** Use this path when `DbAuth` = `NATIVE`, or `DB_HOST_NOT_LOCAL`, or `DB_WINDOWS_ROLE_NOT_POSTGRES`.

1. If `<WorkRoot>\last-failure.json` exists: exit 5 `PATH_B_PREVIOUS_FAILURE`. A person reads the earlier run folder and deletes the file. This stops a scheduled job from causing the same outage again and again.
2. Idle gate (section 7.11).
3. Save the state of the Veeam services (name, status, startup type). Find the stop set: every running service whose name starts with `Veeam`. If a running service outside the stop set depends on one in the set: exit 5 `SERVICE_DEPENDENT_OUTSIDE_SET`.
4. Create the run folder. Back up `pg_hba.conf` and `pg_ident.conf`, and record their SDDL. Run `reg.exe export` of the VBR key, and check that the file is not empty. Write `registry-before.json` with every value the script will change: its old data, or "absent" if it does not exist. Write the marker. Stage = `PATH_B_CHANGING`, so an unexpected error from here on runs the rollback, which also starts the services again. No backup means no change.
5. Idle gate again, then stop the stop set in the updater's stop order, bounded by `ServiceStopTimeoutSec` (section 7.12). The script does not change startup types. If a service does not stop: start the services that this run stopped, remove the marker, and exit 10 `SERVICES_WONT_STOP`. Nothing else has changed yet.
6. Write `pg_ident.conf`, then `pg_hba.conf` (section 7.8).
7. Test (section 7.9). If it fails: rollback.
8. Change the registry (section 9). This includes `PostgresUserForWindowsAuth` = `postgres`, and `SqlHostName` = a loopback address if it is not one already.
9. Record the time T. Start the services that were running in step 3, in dependency order, bounded by `ServiceStopTimeoutSec`.
10. Wait up to `VbrConnectTimeoutSec` for the VBR connect check (section 7.13). If it fails: rollback.
11. Stage = `VERIFIED`. Remove the marker. From here on, the script never rolls back.
12. Clear the `postgres` password (section 7.10).
13. List other roles that have LOGIN and a password in `Detail`. They cannot log in any more.
14. Exit 0, or 5 if step 12 failed.

**Path B rollback.**

1. Stop the stop set (bounded). If a service does not stop, continue, but the result is 50.
2. Restore `pg_ident.conf` and `pg_hba.conf` from the run folder with the section 7.8 routine.
3. Restore the registry from `registry-before.json`: write each old value, and delete each value that was absent. Read every value back and compare. If any value is wrong, import the `reg.exe` export, delete values that were absent, and compare again. If it is still wrong, the result is 50.
4. Start the services that were running before, bounded.
5. The result is 40 only if `VeeamBackupSvc` stays running for `RollbackSettleSec` and no new authentication error (section 7.13 list) appears in `Svc.VeeamBackup.log`. Otherwise 50 `ROLLBACK_FAILED`.
6. Write `<WorkRoot>\last-failure.json` with the run folder and the reason. Remove the marker only on a result of 40.

There is no password to restore in a rollback, because the script clears the password only after `VERIFIED`. The script never saves the password hash.

### 7.7 Marker

- File: `<WorkRoot>\CHANGES-IN-PROGRESS.marker`. Content: run folder path, path (A or B), stage, time.
- Written before the first change in a path. Removed when the path reaches a safe end (rules above).
- If a run finds it: exit 50 `MARKER_PRESENT`. The README gives the manual recovery steps: compare the live files and registry values with the run folder, restore them if needed, start the services, delete the marker.

### 7.8 Writing and restoring the config files

One routine does every write and every restore (Path A, Path B, rollback, trap).

- Read the original bytes. Detect the line ending (CRLF or LF) and keep it. If the file starts with a BOM, do not write the BOM back.
- Kept or commented-out original lines keep their original bytes. Only the prefix `# [VbrStandardise <date>] ` is added, and it is ASCII. Never decode and re-encode original lines.
- New lines are ASCII only.
- `pg_hba.conf`: a header comment with the date and script name, then the six standard lines, then every other original line commented out.
- `pg_ident.conf`: every line that is not in the `veeam` map stays. Removed `veeam` lines are commented out. Required lines are added.
- Write the new bytes to a temp file in the data directory. Swap it in with `[IO.File]::Replace(temp, live, backupPath)`. `backupPath` is a file in the data directory. It is never `$null`. Then:
  - check that the live file exists and its SHA-256 equals the bytes written;
  - check that its SDDL equals the SDDL recorded before the change;
  - delete `backupPath`.
  If any check fails, the write failed: restore the backup bytes with this same routine.
- A restore writes the run-folder backup bytes with this same routine. Never move or copy a run-folder file into the data directory: a move keeps the run folder's ACL, and then the PostgreSQL service account cannot read the file.

### 7.9 SSPI test as SYSTEM

- Before each `psql` run, clear `PGUSER`, `PGHOST`, `PGPASSWORD`, `PGSERVICE` and `PGSSLMODE`. Set `PGPASSFILE` to `nul` and `PGCONNECT_TIMEOUT` to 10. Always pass `-X -w`.
- For each loopback address that listens (preflight step 14): `psql -X -w -h <address> -p <port> -U postgres -d <SqlDatabaseName> -t -A -c "SELECT 1;"`.
- Classify `stderr`:
  - Authentication failure: `SSPI authentication failed`, `no pg_hba.conf entry`, `no match in usermap`, `password authentication failed`, `no password supplied`, or SQLSTATE `28000:` or `28P01:` (the code followed by a colon, as psql and Npgsql print it).
  - Connection failure: refused or timed out.
  Any failure on a listening address fails the test.
- Then check:
  - `SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL` = 0.
  - On PostgreSQL 15 and later: the same for `pg_ident_file_mappings`.
  - `SHOW hba_file` and `SHOW ident_file` equal the files the script edited. Replace `/` with `\`, apply `GetFullPath`, and compare case-insensitively.
- The script cannot log in as `svc_veeam`, because it runs as SYSTEM. It checks the `svc_veeam` line by comparing it with the name built from the account's SID.

### 7.10 Clearing the postgres password

- Send `ALTER ROLE postgres PASSWORD NULL;` to psql through stdin (`-f -`).
- Check `rolpassword IS NULL` again (boolean only).
- If either step fails: `PG_PASSWORD_NOT_CLEARED` (exit 5). No rollback, because VBR works.

### 7.11 Idle gate

- Busy if any of these processes runs: `Veeam.Backup.Manager.exe`, `VeeamAgent.exe`, `Veeam*Explorer*`.
- If the oldest busy process has run longer than `BusyPersistentHours` (for example a log backup or CDP job): exit 5 `VEEAM_BUSY_PERSISTENT`. `ActionRequired`: "Pause log backup or CDP jobs and re-run in a maintenance window".
- Otherwise, if anything is busy: exit 10 `VEEAM_BUSY`.
- The README says Path B stops vPower NFS, so Instant Recovery and published disks stop too. Run `-Apply` in a maintenance window.

### 7.12 Stopping and starting services

- Copy the updater's stop order and dependency-order start. Do not copy the step that sets services to Disabled.
- Stop with `Stop-Service -NoWait`, then poll until stopped or until `ServiceStopTimeoutSec` ends. Never `-Force`.
- Start with `ServiceController.Start()` and `WaitForStatus('Running', timeout)`, bounded by `ServiceStopTimeoutSec` in total.

### 7.13 VBR connect check (Path B step 10)

All three must be true before `VbrConnectTimeoutSec` ends:
- `VeeamBackupSvc` is running.
- `pg_stat_activity` has a backend with `backend_start > T`, `pid <> pg_backend_pid()`, `datname` equal to `SqlDatabaseName` (case-insensitive), `usename = 'postgres'` and `client_addr` `127.0.0.1` or `::1`.
- No line written to `C:\ProgramData\Veeam\Backup\Svc.VeeamBackup.log` after T matches `SSPI authentication failed`, `no match in usermap`, `password authentication failed`, `no pg_hba.conf entry`, `28000:` or `28P01:`.

### 7.14 Known limits

- `hba_file` or `ident_file` set on the PostgreSQL service command line (`-c`) is not detected in preflight. The post-write checks catch it, and the run rolls back (exit 40).
- On success, `Detail` also lists the `pg_hba.conf` lines that were commented out and the roles that still have a password.
- Path B: if a service this run stopped does not start again after `SERVICES_WONT_STOP`, the result is 50 and the marker stays. A service that does not start in step 9 counts as `VBR_DB_CONNECT_FAILED` and runs the rollback.
- Path A sets `PATH_A_DONE` just before it removes the marker, so an error during the removal never restores verified files.

## 8. Security

- RMM should give each server its own password value if it can. A shared password gives an attacker every backup server.
- The script never accepts a password on the command line, and never puts a secret in the arguments of an external program.
- The script never reads or saves the `postgres` password hash.

## 9. Registry switch (closed)

Key: `HKLM\SOFTWARE\Veeam\Veeam Backup and Replication\DatabaseConfigurations\PostgreSql`. Both servers run VBR 12.3.2.3617.

| Value | Kind | Windows auth (`VBR-PILOT01`, after the DBConfig GUI switch) | Native auth (`VBR-PILOT02`) |
|---|---|---|---|
| `SqlActiveConfiguration` (parent key) | String | `PostgreSql` | `PostgreSql` |
| `SqlDatabaseName` | String | `VeeamBackup` | `VeeamBackup` |
| `SqlHostName` | String | `127.0.0.1` | `127.0.0.1` |
| `SqlHostPort` | DWord | `5432` | `5432` |
| `SqlUserName` | String | empty | `postgres` |
| `SqlSecuredPassword` | String | empty | set |
| `PostgresUserForWindowsAuth` | String | `postgres` | `postgres` |
| `SqlLockInfo` | String | XML `CLockInfo` (`Computer`, `UserName`, `Time`) | XML `CLockInfo` |

Only `SqlUserName` and `SqlSecuredPassword` differ.

**Rules:**
- `DbAuth` registry part: Windows when `SqlUserName` and `SqlSecuredPassword` are both empty or absent. Native when either one has data.
- The switch sets `SqlUserName` and `SqlSecuredPassword` to empty Strings. It does not delete them, because DBConfig keeps them as empty values.
- It sets `PostgresUserForWindowsAuth` = `postgres` if the value is absent or different, as a String.
- `SqlHostName`: keep it if it is `127.0.0.1`, `::1` or `localhost`. Otherwise set `127.0.0.1`, or `::1` if only `::1` listens (preflight step 14).
- `SqlLockInfo`: do not change it. DBConfig rewrites it when it saves. The script does not. The pilot on a native server (section 10, step 3) proves that VBR starts without a new `SqlLockInfo`. If it does not, add a rewrite of `Time`, `UserName` and `Id` to this list.
- Read `SqlSecuredPassword` only as "empty or not". Never log it or copy its data anywhere except `registry-before.json` and the `reg.exe` export in the protected run folder.

## 10. Testing

`Test-VbrStandardise.ps1` runs from an elevated prompt under `powershell.exe`. It also loads its functions under `pwsh.exe`.

- `pg_hba.conf` parse and render. Fixtures: the stock PostgreSQL native file, Veeam's default SSPI file, the split-by-role file from VBR-PILOT01, a file with LAN lines, CRLF and LF files, a file with a BOM, and a file with CP1252 bytes in a comment (the bytes must survive unchanged). Check the compliance result and the output bytes for each.
- `pg_ident.conf` render: extra lines commented out, other maps kept, service-account lines kept and added, quotes, case-insensitive compare.
- Service StartName resolution fixtures: `LocalSystem`, `NT AUTHORITY\SYSTEM`, `.\x`, `DOMAIN\x`, a UPN, `NT AUTHORITY\NetworkService`, a gMSA and a name that cannot be resolved.
- SSPI name from a SID (SYSTEM and the current user). Non-ASCII detection.
- Account state evaluation. Inputs: UserFlags, and whether `AccountExpirationDate` is present. Test both shapes.
- Password read: with the environment variable set, the function returns a SecureString of the right length, clears the process variable and writes nothing to output.
- `New-LocalUser` error mapping: a mocked `New-LocalUser` that throws an exception named `InvalidPasswordException` or `NameInUseException` maps to `SVC_PASSWORD_POLICY` or `SVC_NAME_IN_USE`. The summary and log do not contain the test password.
- `psql` stderr classification, and `SHOW hba_file` path compare with `/` and `\`.
- Stage-to-trap-action mapping, exit code precedence and the RMM summary format.
- Child process: AUDIT on a machine without VBR exits 20 `VBR_NOT_FOUND` with a valid summary.
- Child process under `pwsh.exe`: exits 20 `WRONG_POWERSHELL`.

Pilot:
1. AUDIT on a few servers. Review the summaries.
2. `-Apply` on `VBR-PILOT01`. It should take Path A: replace the split-by-role `pg_hba.conf`, clean `pg_ident.conf` and clear the `postgres` password, with no downtime. After this, `pg_native_admin` can no longer log in. If a script or tool uses `pg_native_admin` at that moment, the run stops with `PG_PASSWORD_CONSUMER`.
3. `-Apply` on one server that still uses a password, in a maintenance window, with an RMM timeout of 45 minutes or more.
