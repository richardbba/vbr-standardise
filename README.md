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
- PostgreSQL setups the script cannot edit safely: more than one install (`MULTIPLE_PG`), a running instance that is not the one in the registry (`PG_INSTANCE_MISMATCH`), `hba_file` or `ident_file` set in `postgresql.conf` (`PG_CONF_OVERRIDE`), or `include` lines in `pg_hba.conf` or `pg_ident.conf` (`PG_HBA_INCLUDE`).
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
13. No `hba_file`/`ident_file` override, and no `include` in `pg_hba.conf` or `pg_ident.conf`.
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
4. Remove the marker. Stage `PATH_A_DONE`. If `pg_hba.conf` was rewritten, list the other roles that have LOGIN and a password in `Detail`. They cannot log in any more.
5. Clear the `postgres` password if it is set (`PG_PASSWORD_NOT_CLEARED`, exit 5, if that fails; VBR still works).

Every file write and restore uses one routine: a temp file in the data folder, swapped in with `[IO.File]::Replace`, then a check that the file exists, its SHA-256 matches and its ACL is unchanged. A run-folder file is never moved or copied into the data folder, because it would bring the run folder's ACL and PostgreSQL could no longer read it.

### Path B: full conversion (short outage)

Used when `DbAuth=NATIVE`, or for `DB_HOST_NOT_LOCAL` or `DB_WINDOWS_ROLE_NOT_POSTGRES`.

1. If `<WorkRoot>\last-failure.json` exists: exit 5 `PATH_B_PREVIOUS_FAILURE` (see [last-failure.json](#last-failurejson)).
2. Idle gate: no `Veeam.Backup.Manager`, `VeeamAgent` or `Veeam*Explorer*` process. Exit 10 `VEEAM_BUSY`, or exit 5 `VEEAM_BUSY_PERSISTENT` if the oldest one has run longer than 6 hours (log backup or CDP).
3. Record the Veeam services and find the stop set (every running service whose name starts with `Veeam`). `VeeamBackupSvc` is not running (or not installed): exit 5 `VBR_SERVICE_NOT_RUNNING`, because the switch could not be verified. A service in the set has the startup type `Disabled`: exit 5 `SERVICE_DISABLED_RUNNING`, because it could not be started again. A running service outside the set that depends on one in it: exit 5 `SERVICE_DEPENDENT_OUTSIDE_SET`. Nothing is changed in any of these cases.
4. Create the run folder: `pg_hba.conf.before`, `pg_ident.conf.before`, `services-before.json`, `registry-before.json` (old data of every registry value the script may change, or "absent") and `vbr-key.reg` (a `reg.exe export` of the `DatabaseConfigurations\PostgreSql` key, which must not be empty). Write the marker. Stage `PATH_B_CHANGING`. No backup means no change.
5. Idle gate again, then stop the stop set (at most 5 minutes, never `-Force`, startup types unchanged). If a service does not stop: start every service the script asked to stop again (a service that is still stopping is waited for first), remove the marker, exit 10 `SERVICES_WONT_STOP`. Nothing else has changed. If one of them does not start again: exit 50 `ROLLBACK_FAILED`, and the marker stays.
6. Write `pg_ident.conf`, then `pg_hba.conf`.
7. Test as in Path A. A failure runs the rollback.
8. Switch the registry under `HKLM\SOFTWARE\Veeam\Veeam Backup and Replication\DatabaseConfigurations\PostgreSql`: `SqlUserName` and `SqlSecuredPassword` become empty strings, `PostgresUserForWindowsAuth` becomes `postgres` if needed, and `SqlHostName` becomes `127.0.0.1` (or `::1` if only `::1` listens) if it is not a loopback name. `SqlLockInfo` is never changed.
9. Start the services that were running, in dependency order (at most 5 minutes).
10. Wait up to 10 minutes until `VeeamBackupSvc` runs, a new VBR backend appears in `pg_stat_activity` as `postgres` from loopback, and `Svc.VeeamBackup.log` shows no new authentication error. A failure runs the rollback. The log is read from VBR's log folder: the `LogDirectory` registry value under `HKLM\SOFTWARE\Veeam\Veeam Backup and Replication` if it names a folder that exists, else `C:\ProgramData\Veeam\Backup`. If the log does not exist, `Detail` says that the authentication-error check did not run.
11. Stage `VERIFIED`. Remove the marker. From here on the script never rolls back.
12. Clear the `postgres` password (`PG_PASSWORD_NOT_CLEARED`, exit 5, if that fails).
13. List the other roles that have LOGIN and a password in `Detail`. They cannot log in any more.

**Path B rollback:** stop the stop set, restore `pg_ident.conf` and `pg_hba.conf` from the run folder, restore the registry from `registry-before.json` (and, if a value is still wrong, import `vbr-key.reg` and delete values that were absent), start the services that were running. The result is exit 40 only if `VeeamBackupSvc` stays running for 5 minutes and `Svc.VeeamBackup.log` shows no new authentication error (if the log cannot be found, `Detail` says that this check did not run); otherwise exit 50 `ROLLBACK_FAILED`. Either way the script writes `last-failure.json`. It removes the marker only on exit 40.

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
| `PG_HBA_INCLUDE` | 11 | `pg_hba.conf` uses `include`, `include_if_exists`, `include_dir` or `@file`, or `pg_ident.conf` uses `include`, `include_if_exists` or `include_dir` (PostgreSQL 16 and later). `Detail` names the file. | Standardise by hand. |
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
| `VBR_SERVICE_NOT_RUNNING` | 5 | Path B: `VeeamBackupSvc` is not running (or not installed), so the switch could not be verified. Nothing was changed. | Start the Veeam Backup Service and check that VBR works, then re-run with `-Apply`. |
| `SERVICE_DISABLED_RUNNING` | 5 | Path B: a running Veeam service has the startup type `Disabled`, so it could not be started again after a stop. `Detail` names it. Nothing was changed. | Set a startup type that allows a start (or stop the service) for the services named in `Detail`, then re-run with `-Apply`. |
| `PATH_B_PREVIOUS_FAILURE` | 5 | `last-failure.json` exists from an earlier Path B rollback. | See [last-failure.json](#last-failurejson). |

### Change results

| Code | Exit | Meaning | Action |
|---|---|---|---|
| `SERVICES_WONT_STOP` | 10 | A Veeam service did not stop within 5 minutes. The script started every service it asked to stop again, including one that was still stopping; nothing else changed. (If one of them does not start again, the result is 50 `ROLLBACK_FAILED`.) | Retry later. If it repeats, find out why the service hangs. |
| `PG_SSPI_TEST_FAILED` | 40 | After the write, SYSTEM could not log in or PostgreSQL rejected the files. The script restored them (and, in Path B, the registry and services). | Escalate. Read the transcript and the run folder. |
| `VBR_DB_CONNECT_FAILED` | 40 | After the switch, VBR did not connect to its database within 10 minutes, or a service did not start. The script rolled back. | Escalate. Read `last-failure.json`, the run folder and `Svc.VeeamBackup.log`. |
| `PG_PASSWORD_NOT_CLEARED` | 5 | VBR works with Windows authentication, but the `postgres` password could not be cleared. | Re-run with `-Apply`. |
| `POST_CONVERSION_STEP_FAILED` | 5 | The change was verified and VBR works, but a later step failed (for example removing the marker). Nothing was rolled back. Also reported when a Path B run stopped before any change (`VEEAM_BUSY`, `SERVICES_WONT_STOP`) and could not remove its marker: `Detail` names the marker file. | Read the transcript, then re-run with `-Apply`. For a marker named in `Detail`, delete it first. |
| `ROLLBACK_FAILED` | 50 | A change failed and the restore or rollback also failed. VBR may be down. The marker stays. | Page an operator now. Follow [MARKER_PRESENT: manual recovery](#marker_present-manual-recovery). |
| `UNHANDLED_ERROR` | 20, 40, 50 | An unexpected error. Exit 20 before any database change. Exit 40 when the script restored the files or rolled back and VBR works. (If that restore fails, the result is 50 `ROLLBACK_FAILED`.) After the change was verified it is reported as `POST_CONVERSION_STEP_FAILED` instead. Exit 50 means a second error happened inside the error handler, or an error came after a restore or rollback had already ended (`Stage=ROLLED_BACK`): no further restore or rollback was attempted, and any marker is left as it is. | Read the transcript. Escalate for 40. Page an operator now for 50. |

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
| `Stage` | `UNTOUCHED`, `PATH_A_WRITING`, `PATH_A_DONE`, `PATH_B_CHANGING`, `VERIFIED`, `ROLLED_BACK` (a restore or rollback ran and decided the result) |

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
   - **Keep** (Path B only) if the registry is already switched, both files are standard, `VeeamBackupSvc` runs, the VBR console connects, and `Svc.VeeamBackup.log` (in `C:\ProgramData\Veeam\Backup`, or the folder in the `LogDirectory` registry value) shows no new `SSPI authentication failed`, `no match in usermap`, `password authentication failed`, `no pg_hba.conf entry`, `28000` or `28P01`. Then go to step 7. A later `-Apply` takes Path A and clears the `postgres` password.
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

1. Read the reason and open the run folder it names. Read that run's transcript in `logs\` and `Svc.VeeamBackup.log` (in `C:\ProgramData\Veeam\Backup`, or the folder in the `LogDirectory` registry value) from the time of the run.
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
- Three child-process runs use the real script: an AUDIT under `powershell.exe` on a machine without VBR must exit 20 `VBR_NOT_FOUND` with a valid summary, a run under `pwsh.exe` must exit 20 `WRONG_POWERSHELL`, and an `-Apply` run from a session switched to Constrained Language Mode must exit 20 `CONSTRAINED_LANGUAGE` and write nothing. The AUDIT run is skipped when the machine has a VBR server, is a domain controller, is not elevated, or has an updater marker. The `pwsh.exe` run is skipped when `pwsh.exe` is missing. The Constrained Language Mode run is skipped on a machine with a VBR server, because an AppLocker or WDAC rule that trusts the project folder would run the script in FullLanguage and make that `-Apply` real.

## Pilot order

1. **AUDIT** on a few servers. Review the summaries, especially `DbAuth`, the `pg_hba.conf` lines in `Detail`, and any blocker.
2. **`-Apply` on VBR-PILOT01.** It should take Path A: replace the split-by-role `pg_hba.conf`, clean `pg_ident.conf` and clear the `postgres` password, with no downtime. After this, `pg_native_admin` can no longer log in. If a script or tool uses `pg_native_admin` at that moment, the run stops with `PG_PASSWORD_CONSUMER`.
3. **`-Apply` on one server that still uses a password**, in a maintenance window, with an RMM timeout of 45 minutes or more. It takes Path B. This run proves that VBR starts after the direct registry switch without a new `SqlLockInfo`.
4. Then the rest of the fleet: AUDIT first, `-Apply` in maintenance windows.
