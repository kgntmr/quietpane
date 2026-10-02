# Quietpane 2.1 Internal Security Engineering Review

| | |
|---|---|
| **Release** | Quietpane 2.1.0, published 1 October 2026 (developed in pull request #6) |
| **Date** | September 2026 |
| **Kind of review** | Internal security engineering review and verification, carried out by the maintainer as part of 2.1 development. It is **not** an independent audit, a certification, a penetration test or a formal verification. |
| **Test PC** | Windows 11 25H2 (build 26200), Windows PowerShell 5.1, one administrator account used without and with elevation |
| **Status** | **Release-gate checks on the test PC complete.** Everything marked *Done* below was run and recorded. Everything marked *Outstanding* - mostly checks that need another account, PC or Windows version - has not been, and is listed in [Outstanding verification](#9-outstanding-verification). |

Quietpane does not ask you to trust a vague "secure" label. This report sets out how 2.1 handles administrator rights, what risks were found in the design it replaces, what changed, how each change was tested, and what limits remain. The evergreen description of the design is in [SECURITY.md](../../../SECURITY.md#how-quietpane-uses-admin-rights). This page is the release-specific evidence.

## Contents

1. [Executive summary](#1-executive-summary)
2. [How to read this report](#2-how-to-read-this-report)
3. [Risks identified during development](#3-risks-identified-during-development)
4. [Architecture changes](#4-architecture-changes)
5. [Risk, response and verification at a glance](#5-risk-response-and-verification-at-a-glance)
6. [Verification performed](#6-verification-performed)
7. [Protected machine-store isolation](#7-protected-machine-store-isolation)
8. [Known limitations](#8-known-limitations)
9. [Outstanding verification](#9-outstanding-verification)
10. [Problems found by the verification itself](#10-problems-found-by-the-verification-itself)
11. [Where to look in the code](#11-where-to-look-in-the-code)

## 1. Executive summary

Until 2.0, Quietpane asked Windows for administrator rights the moment it started, and everything it did - reading your PC's health, the Safety scan, changing your own settings - ran with those rights.

Quietpane 2.1 turns that round:

- **It opens without administrator rights.** Reading your PC, the Safety scan and changes to your own account need none, so none are asked for.
- **Windows' shield marks the actions that need them** - a service, a machine-wide setting, the quarantine.
- **Saying yes to Windows changes nothing by itself.** Quietpane reopens with administrator rights on the same tab, with the same boxes ticked, and waits. You press the action again.
- **Your own state and the PC's protected state are kept apart**, in `%LOCALAPPDATA%\Quietpane` and an administrators-only `%ProgramData%\Quietpane`.
- **The administrator window decides for itself what it trusts.** Anything a non-administrator could have written - a command-line argument, a file in your profile, any record from before 2.1 - is treated as untrusted input.

The principle the design is built on:

> **The unelevated process may describe what the user wants; the elevated process independently decides what it is allowed to trust and execute.**

## 2. How to read this report

Every claim in this report is one of these, and is labelled where it matters:

| Label | Meaning |
|---|---|
| **Design** | What the architecture intends. |
| **Code** | Enforced in `src/Quietpane.psm1` or `Quietpane.ps1`; see [Where to look in the code](#11-where-to-look-in-the-code). |
| **Automated** | Checked by `tests/Run-QuietpaneTests.ps1` or the window's `-SelfTest`, on every run. |
| **Real Windows** | Observed on the test PC with real Windows prompts, accounts, permissions or tools. |
| **Outstanding** | Not yet verified. Never counted as done. |

Machine-specific details (account names, SIDs, local paths) are left out. Paths under a profile are written `C:\Users\<user>\...`.

## 3. Risks identified during development

These were found by reading the 2.0 code and by checking a real PC before 2.1 was written. They describe the problem, the kind of impact and the response - not how to exploit them. **They affect Quietpane 2.0 and earlier.** Each needs another program or account already on the same PC.

| # | Area | Problem in 2.0 | Kind of impact | 2.1 response |
|---|---|---|---|---|
| R1 | Shared data folder | `%ProgramData%\Quietpane` inherited Windows' default permissions, so ordinary accounts could create and change files there. On the test PC the folder was owned by a user account rather than Administrators, and carried an inherited *Users: Write* entry. | Integrity of everything stored there | New state lives in a folder created and locked by the administrator window ([4.6](#46-state-separation)) |
| R2 | Undo records | Undo replayed whatever a restore record in that folder described. A record can stand for registry, file, service, scheduled-task, environment-variable and hosts-file changes. | A record written without administrator rights could steer a change later made with them | Old records are view-only ([4.7](#47-legacy-restore-records)); new ones are strictly validated ([4.8](#48-restore-point-validation)) |
| R3 | Quarantine | The quarantine lock was applied once, when the folder was created, and a failure went unnoticed. Putting a file back trusted the recorded original path. | Integrity of quarantined files and where they are restored to | Lock checked before every use, strict metadata, path and hash checks ([4.9](#49-quarantine)) |
| R4 | Undo bookkeeping | Several changes recorded their undo entry *before* the change was known to have worked. | Undo could "restore" something that was never changed | Undo entries only after a confirmed change ([4.11](#411-mutation-outcomes)) |
| R5 | Silent failure | Some writes could fail without being reported (for example the hosts file, machine environment variables, removing provisioned apps, parts of Undo). | The app could report success it had not achieved | Every write reports its real outcome ([4.11](#411-mutation-outcomes)) |
| R6 | Another administrator | On a standard account, the administrator who approves Windows' prompt is a different account. An app running with their token writes *their* per-user settings (HKCU), not the asking user's. | Changes silently applied to the wrong account | SID-based identity; per-user changes refused under another account ([4.12](#412-alternate-administrator-accounts)) |
| R7 | Reading without rights | A read that failed for lack of rights could look like "nothing found", "0 KB" or "already off". | Misleading results, a false sense of safety | Reads say *needs admin rights* instead ([4.13](#413-read-availability)) |
| R8 | Whole-app elevation | The whole app, including every read and the scan, ran with administrator rights. | Unnecessary privileged code | Unelevated by default ([4.1](#41-unelevated-by-default)) |

## 4. Architecture changes

### 4.1 Unelevated by default

**Code.** The 2.0 self-elevation at start-up is gone; Quietpane runs with the rights of the account that started it. `Safety scan only` (`-Scan`) and the sign-in check (`-Watch`) also run without administrator rights. **Real Windows:** the ordinary window, `-Watch` and `-Scan` were all started with an unelevated token on the test PC, with no prompt ([6.5](#65-real-windows-verification)).

### 4.2 UAC on demand

**Code.** Windows' own shield icon is drawn on a control only when the action behind it needs administrator rights, recomputed as boxes are ticked. Every shielded control has an accessible name and help text. The quarantine and "Changes made with admin rights" buttons are always shown in the ordinary window, because working out whether there is anything behind them would mean looking inside the protected folder ([4.6](#46-state-separation)).

### 4.3 Two-step privileged execution

1. You tick what you want and press the action.
2. If any part needs administrator rights, Quietpane asks Windows (UAC) and changes nothing yet - not even the parts that would not need rights, so one click is one decision.
3. If you say yes, a new Quietpane opens with administrator rights, on the same tab, with the same valid boxes ticked and a note saying so.
4. **Nothing happens automatically.** No argument passed to the new window can start a change.
5. You press the action again, and see the same preview and confirmation as always.
6. The engine validates the whole batch, then each single change, and only then writes.

**Code.** The arguments are built from a closed vocabulary (tab names, item ids, a GUID, a SID); anything outside it is refused before launch rather than escaped. The new window treats them as untrusted and only selects a tab and ticks boxes that really exist there. The first window stays open, disabled, until the new one is visibly up, and comes back if you say no or the new window fails. Only one Quietpane window is usable at a time.

**Automated:** argument vocabulary, hostile values, a real child PowerShell receiving every value exactly (including from a path with spaces, symbols and Unicode), and the handoff state machine (declined, launch failure, child exits, slow child, a third instance, console flash) are tested. **Real Windows:** the readiness signal was measured on a real `RunAs` launch ([6.5](#65-real-windows-verification)). The full shield-to-second-click flow was checked through real prompts on the test PC, declined and accepted, with both terminal hosts ([6.5](#65-real-windows-verification)).

### 4.4 Scope and privilege

Every change is first described as an *operation* - its kind and exact target, and for an uninstaller the exact command. Two questions are answered separately:

| Question | Values | Example |
|---|---|---|
| **Scope** - whose state changes | `User` (this account), `Machine` (the whole PC); an item made of both is `Mixed` | Your startup apps: User. A Windows service: Machine. |
| **Privilege** - what it takes | `User` (an ordinary token), `Admin`; `RuntimeCheck` for targets whose permissions genuinely vary | `HKCU\Software\Policies` is User scope but needs Admin. |

`RuntimeCheck` is answered by opening an *existing* registry key for access and closing it. It never creates a key, a value, a task or a permission to find out, and any doubt counts as `Admin`. **In 2.1 no shipped target is classified `RuntimeCheck`**; the class and its probe are in place and tested for later use.

Uninstallers are classified from what would actually run. One registered for your account runs without the shield only if its program lives in your own profile, has no link or junction on the way, and its manifest - read from the program's real resource table, never a text search - asks to run as the invoker. Windows Installer commands, wrappers, missing files, unexpandable variables and anything else Quietpane cannot classify with certainty need administrator rights.

### 4.5 Engine enforcement

**The shield is presentation only.** The boundary is enforced in the engine (**Code**):

- **Operation descriptors** for every change, built before anything is written.
- **Batch preflight** (`Test-QpBatchPlan`): every operation in Apply, Quiet my PC now, Undo or removing brand extras is validated first. If any one is not allowed, the whole batch is refused, with no write and no restore point.
- **Per-operation enforcement** (`Assert-QpOperation`): each single change is checked again just before it happens, so a caller that skipped preflight still cannot write.
- **Identity by SID** (`Set-QpActor`), never by account name.
- **Safe defaults:** anything that cannot be classified with certainty needs administrator rights, and in an administrator window working for another account it is refused.

**Automated:** admin changes called directly without rights are refused before anything is touched; skipping the batch check still gets every change refused; one uncatalogued change in a batch refuses the whole batch with nothing written.

### 4.6 State separation

| Store | Holds | Who can use it |
|---|---|---|
| `%LOCALAPPDATA%\Quietpane` | Your settings, notes, "Leave it for now" choices, and restore points for changes made with your own rights | Your account. The administrator window writes here only for the same account, only after checking the folder and file are not links, and through a temporary file. Only the ordinary window replays these restore points. |
| `%ProgramData%\Quietpane` | Restore points for changes made with administrator rights (`machine\points`), their audit log, the quarantine (`machine\quarantine`) | Administrators and SYSTEM only. Locked by the first 2.1 administrator window: owner Administrators, inheritance off, exactly two entries, read back and checked before every use. |

**Design and Code:** the ordinary window never reads, lists or writes anything under `%ProgramData%\Quietpane`. The only function that returns a path there refuses unless it is running with administrator rights and the lock has been verified in this process. **Automated** and **Real Windows** evidence is in [section 7](#7-protected-machine-store-isolation).

**Real Windows:** on the test PC the first 2.1 administrator window changed the 2.0 folder from *owned by a user account, with inherited Users read and write* to *owner Administrators, protected, SYSTEM and Administrators full control only*. A probe confirmed that applying the lock did not follow a junction.

### 4.7 Legacy restore records

Because the pre-2.1 folder could be changed by any account on the PC, **no record made before 2.1 can be shown to be genuine** - and changing its permissions or owner today cannot prove what it contained yesterday. So 2.1:

- lists older records by folder name only, in the administrator window, labelled *made by an older Quietpane*;
- never opens their `state.json`, never replays them, never promotes them into a 2.1 record;
- never modifies or deletes them, and leaves the older `%ProgramData%\CleanMyPC` folder's permissions alone.

**Automated:** older points are listed and cannot be undone even with perfectly valid contents; listing never opens `state.json` (the test denies read access to it); locking an older point to administrators does not make it trusted. **Real Windows:** the test PC holds 17 records from 2.0 and one from the older CleanMyPC name. The admin window's listing of them has been checked by the automated tests only; a recorded visual check on the real PC is **Outstanding**.

### 4.8 Restore-point validation

Every 2.1 restore point is read with a strict schema before anything is replayed (**Code**, `Read-QpRestorePoint`):

- a known schema version, exact fields and exact JSON types, no unknown, missing, duplicated or case-varied keys, and size and count limits;
- only the entry types Quietpane writes;
- every target on an allow-list of what Quietpane itself changes: catalogued registry values, the StartupApproved keys, catalogued services, tasks and variables, the VS Code settings file of the point's own account, and Quietpane's own tagged hosts lines;
- scope and privilege **re-derived** for each entry, never read from the file: a point in your own store that holds an admin-only change is refused;
- the point folder, `state.json` and every backup checked for owner, lock and links; a backup must be a plain file inside the point folder;
- no path to a restore destination is ever taken from the record without these checks.

Anything unexpected refuses the whole point. Nothing is "made safe" and replayed.

### 4.9 Quarantine

- **Protected storage.** `machine\quarantine` carries its own protected lock (Administrators and SYSTEM only, no inheritance), so it stays shut even if the parent folder's permissions are ever changed.
- **Fresh copies.** A quarantined file is copied into a new file there, so it takes the quarantine's lock instead of keeping its own permissions, checked against its SHA256, and only then removed from where it was. Putting it back works the same way in reverse.
- **Strict metadata.** `meta.json` is read with a strict schema (the 2.1 form, and exactly the form 2.0 wrote), with a size limit. The item folder must hold exactly its two files, owned by Administrators or SYSTEM.
- **Path checks.** A file goes back only to a local, existing folder outside Windows and outside another account's profile, never over an existing file, never through a link, and only if its hash still matches.
- **Legacy quarantine.** On the test PC the 2.0 quarantine folder turned out to be owned by a user account rather than Administrators, so 2.1 cannot vouch for what is in it. Items quarantined by 2.0 are listed by name only, and never opened, put back, moved or deleted by Quietpane. An administrator can still copy one out by hand.

### 4.10 Reparse points, junctions and links

Before privileged state is read or written, the path is resolved and every level is checked for reparse points (junctions, symbolic links and similar). The protected folder is scanned before its lock is applied - if a link exists anywhere below it, the permissions are left alone and the folder is refused - and scanned again after. New privileged files are only ever created inside folders Quietpane has locked. Clearing a folder never follows a link inside it; the link itself is removed or skipped.

This **reduces** check-then-use races; it does not remove them. See [Known limitations](#8-known-limitations).

### 4.11 Mutation outcomes

Every change reports one of four outcomes:

| Outcome | Meaning | Undo entry |
|---|---|---|
| `Changed` | Written, and read back where that is possible | Yes - only now |
| `Unchanged` | Already as asked | No |
| `Failed` | Tried, and Windows refused or the read-back disagreed | No |
| `Refused` | Not allowed; nothing was touched | No |

A batch with a runtime failure is saved as *partial*, the summary counts each outcome separately and never claims "done", and Undo marks a point undone only when every entry ended `Changed` or `Unchanged`.

### 4.12 Alternate administrator accounts

The administrator window compares the account that asked (passed as a SID, validated) with the account whose token it holds (**Code**, `Set-QpActor`, `Test-QpSameUser`):

- **Same account:** your own and machine-wide changes are allowed, subject to every other check.
- **Different account, or the asking account unknown:** only batches whose every operation is machine-wide may run. Anything touching the asking account's settings - including a machine change that reads them - refuses the whole batch before anything is written. Nothing is saved into either account's folders, and the sign-in start is refused.

**Automated:** a mixed batch under another administrator is refused whole with nothing written; a machine-only batch is allowed; an account that merely shares a display name is still another account. **Real Windows** with a genuinely different administrator account is **Outstanding**.

### 4.13 Read availability

Reads that can be blocked report `Available`, `NeedsAdmin` or `Unavailable` alongside the value. A permission failure is never shown as "not found", "0 KB", "already off" or "nothing to clean". The window says *needs admin rights to check*, and the scan summary names exactly what it could not see without them. **Real Windows:** the ordinary window's status line reads *"Some checks need admin rights: system tasks Windows hides, the size of Windows' own temporary files and Windows' own restart timing."*

### 4.14 Sign-in start

The optional sign-in task now runs Quietpane with limited rights (it ran with highest privileges in 2.0), is registered for the asking account only, and is refused under another account. An existing task is moved to limited the next time an administrator window opens for the same account. **Automated**, and observed on the test PC. The next sign-in starting Quietpane unelevated is **Outstanding**.

## 5. Risk, response and verification at a glance

| Area | Risk identified | 2.1 response | Verification |
|---|---|---|---|
| Startup privilege | Whole app ran elevated | Unelevated start; UAC only on demand | Real Windows (unelevated token, no prompt) |
| Elevation handoff | Arguments could carry intent into an admin process | Closed vocabulary; view-only restore; nothing runs until the second click | Automated; real `RunAs` readiness check; real prompt declined and accepted, both terminal hosts |
| Restore state | Historical records could not be trusted | Legacy records view-only; new ones strictly validated | Security regression tests |
| Privileged actions | The window could misclassify an action | Engine preflight plus per-operation enforcement | Direct-engine tests |
| Alternate admin | Per-user changes could land in the wrong account | SID-based scope checks | Identity tests; real second account **Outstanding** |
| Machine store | Historically user-writable path | Fresh folders inside a verified, admin-only lock | ACL tests; real ACL before/after; Process Monitor |
| Quarantine | Metadata and path trust; inherited permissions | Strict schema, fresh copies, hashes, path rules | Security tests (admin-only ones run elevated) |
| Links and junctions | Redirecting privileged paths | Reparse rejection at every level; non-following deletion | Adversarial tests; real propagation probe |
| Outcomes | Undo written before success; silent failures | Four outcomes; undo only after `Changed` | Outcome tests |
| Reads | Permission failures looked like "nothing" | `NeedsAdmin` states, named in the scan summary | Availability tests; real status line |

## 6. Verification performed

The test, self-test and Process Monitor output behind this section is published, cleaned of machine-specific details, in [docs/security/evidence/2.1](../evidence/2.1/README.md).

### 6.1 Automated functional tests

`tests/Run-QuietpaneTests.ps1` runs the engine and the catalogues directly, with fake inputs where Windows state would otherwise be needed. Since 2.1 every run uses its own stores in a fresh folder under `%TEMP%`, and the last two tests confirm that the real `%LOCALAPPDATA%\Quietpane` (and, with administrator rights, the real `%ProgramData%\Quietpane`) is byte-for-byte unchanged afterwards.

The 2.1-specific functional sections cover the privilege map (every privacy setting classified from its own changes, with counts checked on real Windows), scope versus privilege, uninstaller classification, engine enforcement, outcome reporting, read availability, the per-account store and settings carried over from 2.0, and the limited sign-in task.

### 6.2 Security regression tests

Representative cases, each an automated test (**Automated**). Names are paraphrased from the test file.

| Category | What is tested |
|---|---|
| Malformed privileged JSON | Malformed, oversized, over-long and unknown kinds of restore point are refused cleanly |
| Unknown, missing, duplicate fields | Unknown, missing, wrong-typed, duplicated or oddly spelled fields refuse the whole point |
| Arbitrary registry targets | Another hive, an arbitrary HKLM key, odd spellings and uncatalogued HKCU keys are refused |
| Arbitrary file destinations | File restores only to the account's own VS Code settings, with a backup inside the point, never through a link; putting a quarantined file back refuses Windows, another account's profile and existing files |
| User point holding privileged work | A point in your own store may not hold admin-only changes; an administrator window never replays a point from your own store |
| Reparse points and junctions | A store that is a junction, or holds one anywhere, is refused and its permissions left alone; clearing a folder never follows a link inside it |
| ACL takeover | Any extra entry, or inheriting from above, fails the lock check; a 2.1 folder someone else created first is never adopted; a Users entry on the parent never reaches the quarantine |
| Quarantine records | An item holding anything but its two files, or described in an unknown form, is refused; one that checks out in every other way is still refused unless administrators own it |
| Legacy state | Older points are listed, never replayed, never opened, and not trusted after being locked |
| Alternate SID | Mixed batches refused under another administrator; identity is the SID, not the name |
| Batch rejection with zero writes | One disallowed change refuses the whole batch, with nothing written and no restore point |
| Argument transport | Closed vocabulary; hostile notes and wrong-tab ticks dropped; a real child PowerShell receives every value exactly |
| Privilege probes | The probe opens an existing key and changes nothing; it never creates a missing key, a value, an undo entry or a restore point |
| Uninstaller classification | Your own `asInvoker` uninstaller needs no shield; `requireAdministrator`, Windows Installer and unclassifiable commands do; the right words in a file without a real manifest are not trusted |
| Machine-store isolation | Nothing outside the engine names the machine store; without administrator rights, reading the PC, the sign-in check, Undo and quarantine never touch it; your own Undo only reads your own store |

### 6.3 Elevated and unelevated runs

The suite was run both ways on the test PC on 30 September and 1 October 2026, on the final code in pull request #6.

| Run | Passed | Failed | Skipped | What was skipped |
|---|---|---|---|---|
| Without administrator rights | **326** | **0** | 15 | 13 tests that need administrator rights (quarantine storage and round trip, permanent deletion, the Recycle Bin, the audit log, the sign-in start, Windows' restart record, the machine-store and quarantine locks, putting a quarantined file back); EICAR (needs `-Live`); and one check that only runs on a PC without Defender |
| With administrator rights | **339** | **0** | 2 | EICAR (needs `-Live`), and the check that only runs on a PC without Defender |

Before and after each elevated run, every file's SHA256, size and time, and every folder's permissions, under the real machine folder were recorded: **unchanged** both times.

### 6.4 Window self-tests

`Quietpane.ps1 -SelfTest` builds the whole window without showing it and checks it, including the shield on every control that needs it, relaunched views that tick only real items and change nothing, and the handoff state machine with a simulated prompt. On the final build it passed in light and dark, without and with administrator rights, and again from the release ZIP extracted to a folder named `qp final & 100% (1)` in light and dark: every check true, 0 unnamed controls.

**Static checks on the final code:** every script file is plain ASCII with CRLF line endings; native-code imports are unchanged (6 in the engine, 3 in the window); the network-code search in the README finds exactly its two expected matches, both detection patterns.

### 6.5 Real-Windows verification

All on the test PC, 30 September 2026 unless stated.

| Check | Status | Evidence |
|---|---|---|
| Ordinary start: no prompt, unelevated token | **Done** | Every Process Monitor run below; the harness read the token's elevation (0) |
| "Needs admin rights" states in the ordinary window | **Done** | Status line quoted in [4.13](#413-read-availability) |
| Static shield buttons (quarantine, machine Undo) with help text | **Done** | Found by UI Automation with the expected help text |
| A change of your own with no prompt, and its Undo with no prompt | **Done** | MSI Center's startup entry switched off and undone through Quietpane; the real registry value read back from outside the app each time; Apply showed no shield |
| `-Watch` (sign-in check) unelevated | **Done** | Started as the sign-in task starts it, then opened from the taskbar |
| In-window Safety scan unelevated, to completion | **Done** | 34.9 minutes under Process Monitor; report produced |
| `Safety scan only` (`-Scan`) unelevated, to completion | **Done** | 41.5 minutes under Process Monitor; report produced ([7](#7-protected-machine-store-isolation)) |
| Machine-store lock applied and verified | **Done** | Owner, protection and entries read before and after the first 2.1 administrator window |
| Lock propagation does not follow a junction | **Done** | Real probe on the test PC |
| Elevated token's default owner | **Done** | BUILTIN\Administrators, so new privileged files are owned by Administrators |
| Elevated test suite executes the admin-only tests | **Done** | [6.3](#63-elevated-and-unelevated-runs) |
| Readiness signal of a real `RunAs` child | **Done** | The child briefly reports its console, titled "Windows PowerShell", as its main window (about 0.3 s) before Quietpane's window appears; `HasExited` works on it. This is why only a window titled Quietpane counts as ready. |
| UAC declined through the shield | **Done** | 1 October 2026, by the maintainer by hand: Apply on a shielded Privacy item, **No** at the prompt; nothing changed and the original window stayed usable |
| UAC accepted: tab and ticks restored, nothing runs, second click, restore point, Undo | **Done** | 1 October 2026, by hand: **Yes** at the prompt; the admin window opened on the same tab with the same tick and ran nothing by itself; Apply pressed again made the change; Undo put it back |
| Handoff with Windows Terminal and with Windows Console Host as the default terminal | **Done** | 1 October 2026, by hand: the accepted handoff repeated with each as the default terminal; the setting was then returned to "Let Windows decide" |
| First administrator window for the same account updates the installed copy | **Done** | Observed on 1 October 2026: the installed 2.0 copy in Program Files became 2.1, and the Start-menu shortcut was left unchanged |
| Sign-in task moved from highest to limited | **Done** | Observed at the same time: run level Highest became Limited, same command line |
| Next sign-in starts Quietpane unelevated | **Outstanding** | |

## 7. Protected machine-store isolation

**The invariant:** an unelevated Quietpane process must not read, list, create, change or delete anything under `%ProgramData%\Quietpane`. This is a release gate for 2.1: a non-zero result blocks the release, and the fix is to change the architecture, never to loosen the folder's permissions.

**Automated.** The release-gate tests check that nothing outside the engine names the machine store, and that reading the PC, the sign-in check, Undo and the quarantine, run without administrator rights, never touch a test machine store.

**Real Windows (Process Monitor).**

| | |
|---|---|
| Tool | Process Monitor 4.11, Microsoft Sysinternals, Authenticode signature by Microsoft Corporation verified as valid |
| Date | 30 September 2026 |
| Filter | *Path contains* each spelling of the store - `ProgramData\Quietpane` and the 8.3 short forms (`PROGRA~3`, `QUIETP~1`) - plus, as a positive control, the app's own `src` folder. Filtered-out events dropped. Every process included, System (PID 4) too. |
| Process scope | The ordinary Quietpane tree: the launcher, PowerShell and its console, started through Explorer with the owner's ordinary rights. Each process's token was read as it appeared (elevated = 0). Everything else is reported separately, never counted as Quietpane. |
| Positive controls | The (elevated) test harness checks that `%ProgramData%\Quietpane\machine` exists at the start and end of each capture, proving the filter records that exact path. The ordinary Quietpane's reads of its own `src` folder prove its activity was captured. |

| Capture | Surfaces exercised | Quietpane events captured | Accesses to the store by the ordinary Quietpane | Other events under the store |
|---|---|---|---|---|
| 1 | Start-up, Home, Health, Privacy, Telemetry, Apps (including startup costs), Free up space with *Where your space went*, Settings, the Undo tab and its static shielded button, the Safety scan tab and its static quarantine button, a change of your own (MSI Center startup) and its Undo | 6,236 reads of `src` | **0** | 5, all the harness's own control |
| 2 | `-Minimized -Watch`, then opened from the taskbar | 2,622 reads of `src` | **0** | 10, all the harness's own control |
| 3 | The in-window Safety scan, to completion (34.9 min) | 4,120 reads of `src` | **0** | 10 harness control; 1 System (PID 4) `IRP_MJ_CLOSE` on the store's root folder |
| 4 | `Safety scan only` (`-Scan`), to completion (41.5 min), including writing its report | 1,805 reads of `src` | **0** | 11 harness control; 6 System (PID 4) |

Capture 1 was run on the release candidate; its `-Watch` step failed because of a fault in the test harness (not in Quietpane) and was repeated as capture 2. Earlier attempts of capture 1 that stopped part-way, also for harness reasons, recorded no accesses either.

An earlier -Scan capture that was closed after about 40 minutes also recorded zero accesses from the ordinary Quietpane while it ran. In that capture, Defender (`MsMpEng`) and one elevated PowerShell process (consistent with the installed 2.0 being opened with administrator rights) read files at the store's root; neither was the ordinary Quietpane.

**Result: zero accesses from the ordinary Quietpane process tree in every capture.** System (PID 4), Defender and elevated processes are outside the invariant and are recorded here only for completeness.

Not covered by these captures: a shielded click answered *No*. The UAC checks are separate sessions, run without Process Monitor by design.

Raw captures (`.PML`, `.CSV`) are not published: they are large and contain machine-specific paths and process details. A cleaned summary of each capture, listing every event under the store, is in [evidence/2.1](../evidence/2.1/README.md).

## 8. Known limitations

- **Your own two windows are not a Windows security boundary.** Windows does not treat one account's ordinary and administrator processes as separate security principals. Quietpane hardens the handover between them - untrusted arguments, view-only relaunch, strict records - but cannot turn it into a boundary. The design is built to hold against *another* account, or data another account could write, steering a change made with administrator rights.
- **Check-then-use races are reduced, not removed.** Paths are checked immediately before each use, links are refused at every level, new files are created only inside locked folders and deletion never follows a junction. Closing the remaining window entirely would need handle-based native calls, which Quietpane deliberately does not add. The largest remaining window is the first time a 2.1 administrator window locks an existing `%ProgramData%\Quietpane` while someone else on the PC is actively racing it.
- **A script run from a folder you can write to can be changed by you - or anything running as you - before you say yes.** This is inherent to an unsigned script. When Quietpane has been installed, it starts its own copy from `C:\Program Files\Quietpane`, which ordinary programs cannot change. Code signing is [applied for](../../../README.md#code-signing-policy).
- **Windows versions and configurations differ.** Ownership defaults, inherited permissions and UAC settings vary between Windows builds, domain policies and account types. The results here are from one Windows 11 PC and one administrator account.
- **Some checks need other accounts, other PCs or other Windows versions**, and are listed below rather than assumed.
- **Windows 10 has not been re-verified for 2.1.** Quietpane supports Windows 10 and 11; the 2.1 shield icon and handover on Windows 10 are outstanding.
- **Pre-2.1 records cannot be replayed.** This is deliberate, and it means settings changed by 2.0 have to be changed back in Windows by hand if wanted.
- **This review was carried out by the project itself.** No independent party has audited it.

## 9. Outstanding verification

**On the test PC:**

- the next sign-in starting Quietpane unelevated, now that the task runs with limited privileges;
- the admin window's listing of the PC's real pre-2.1 records, checked by eye;

**Needs another account, PC or Windows version** (also listed in [docs/manual-checks.md](../../manual-checks.md#3a-admin-rights-since-21)):

- a standard account with a different administrator answering the prompt;
- a Microsoft account and a local account, for the sign-in start;
- Windows 10, for the shield icon and the handover;
- a Windows user name with non-English letters;
- a PC with older `CleanMyPC` restore points, checked by eye.

This report will be updated as these are completed.

## 10. Problems found by the verification itself

Verification changed the code, which is the point of doing it. In the order they were found:

| Found | What was wrong | Change |
|---|---|---|
| Real ACL check | The 2.0 quarantine folder on a real PC belonged to a user account, not Administrators, so it could not be trusted | Quarantine moved to a new `machine\quarantine`; 2.0 items made view-only |
| Real quarantine round trip | A file *moved* into quarantine kept its original owner and permissions | Files are copied into a fresh file that takes the quarantine's lock, checked by hash, then removed |
| Elevated self-test | The handoff self-test failed when the window already had administrator rights | The self-test simulates an ordinary window for that check |
| Elevated test run | Admin-only tests wrote into the real `%ProgramData%\Quietpane\machine` | Every run now uses its own stores under `%TEMP%`; two tests prove the real folders are left exactly as they were |
| Elevated self-test | Drawing the quarantine list checked and locked the real machine store | The self-test draws an empty quarantine and changes nothing |

## 11. Where to look in the code

| Topic | Where |
|---|---|
| Scope, privilege and operation policy | `New-QpOperation`, `Get-QpOperationPolicy`, `Get-QpUninstallPrivilege` in [`src/Quietpane.psm1`](../../../src/Quietpane.psm1) |
| Batch preflight and per-operation enforcement | `Test-QpBatchPlan`, `Assert-QpOperation` |
| Identity | `Set-QpActor`, `Test-QpSameUser` |
| Stores and the machine-store lock | `Get-QpUserStorePath`, `Protect-QpMachineStore`, `Get-QpMachineStorePath`, `Test-QpReparseFree` |
| Restore points | `Read-QpRestorePoint`, `Invoke-QpUndo` |
| Quarantine | `Invoke-QpQuarantine`, `Copy-QpFileFresh`, `Get-QpQuarantineItems`, `Get-QpLegacyQuarantine`, `Restore-QpQuarantineItem`, `Remove-QpQuarantineItem` |
| Arguments for the administrator window | `ConvertTo-QpArgumentString`, `Test-QpElevationArguments` |
| Handoff and shield | `Request-Elevation`, `Set-ShieldState` in [`Quietpane.ps1`](../../../Quietpane.ps1) |
| Tests | [`tests/Run-QuietpaneTests.ps1`](../../../tests/Run-QuietpaneTests.ps1), sections marked *(2.1)*, *(security)* and *(release gate)* |
| Manual procedures | [`docs/manual-checks.md`](../../manual-checks.md#3a-admin-rights-since-21) |

To report a problem with anything described here, see [Reporting a vulnerability](../../../SECURITY.md#reporting-a-vulnerability).
