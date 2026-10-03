# Security Policy

## Reporting a vulnerability
Please **don't** open a public GitHub issue for security problems.
Email **info@komodoworks.com** with the subject **"Security: Quietpane"**, and include:
- the version (shown in the app footer and in scan reports)
- what you found, and the steps to reproduce it
- your Windows version

We aim to acknowledge reports within **5 working days**, agree a fix and a disclosure date with you, and credit you in the release notes if you'd like.

## Supported versions
Security fixes go into the latest release. **Only the current release is published:** when a new one goes out, the previous one is removed, so everyone downloads the same, current version. The download link on the [README](README.md) always points at it.

## Our approach

- **Admin rights only when the action needs them.** Quietpane opens with your own rights. Windows' permission prompt (UAC) appears only for a change to Windows itself, and saying yes never runs anything by itself.
- **Offline.** No telemetry, no accounts, no network connections of any kind.
- **The engine decides, not the window.** What an administrator window will run is checked by the code that runs it, against what that code itself trusts - never against what a button, an argument or a file says.
- **Nothing to take on trust.** The app is plain text you can read, and for changes that touch administrator rights we publish the reasoning, the tests and the limits (see [Security reviews](#security-reviews)).

## What Quietpane assumes

- **Windows and the PC's administrator accounts are not compromised.** Anything already running with administrator rights can change Quietpane, and everything else on the PC.
- **The administrator who answers the prompt is trusted with the whole PC, but not with your own settings.** If that is a different account, only machine-wide changes are allowed.
- **Other accounts and programs on the PC may be hostile.** Nothing they could have written - including anything Quietpane stored before 2.1 - is trusted by an administrator window.
- **The copy you run is genuine** ([how to check](#check-that-your-download-is-genuine)), and if you run it from a folder you can write to, nothing running as you has changed it.
## How Quietpane uses admin rights

Since 2.1, Quietpane opens with the rights of the account that started it and asks Windows for administrator rights only when a change needs them. This section is for people reviewing the code; the everyday version is [The shield](README.md#the-shield).

**The rule it is built on:** the ordinary window may describe what you want; the administrator window decides for itself what it trusts and runs. Nothing the ordinary window, another program running as you, or another account on the PC can write is allowed to steer a change made with administrator rights.

**Scope and privilege are two questions.** Every change is described first as an *operation* (its kind, its exact target, and for an uninstaller the exact command). For each one the engine works out, separately:
- *scope* - whose state it changes: your account's (`User`) or the whole PC's (`Machine`);
- *privilege* - what it takes to change it: your own rights or administrator rights.

`HKCU\Software\Policies`, for example, is your account's but needs administrator rights. A brand app's uninstaller registered for your account only runs without a prompt if its program lives in your own profile, has no link or junction on the way to it, and its manifest - read from the program's real resource table, never a text search of the file - asks to run as the invoker. Anything else, including anything Quietpane can't classify with certainty, needs administrator rights. Deciding this never changes anything: a check opens an existing registry key for access and closes it, and never creates a key, a value, a task or a permission to find out.

**Enforced in the engine, not the window.** The shield is only a picture. A whole batch - Apply, Quiet my PC now, Undo, removing brand extras - is checked before its first write, and refused whole with nothing written if any part isn't allowed. Every single change checks again just before it happens, so a bug that skips the batch check still can't write. Each change reports what really happened (changed, unchanged, failed or refused); an undo record is written only after a change has actually been made and read back.

**Handing over to the administrator window.** Pressing a shielded button starts Quietpane again through Windows' permission prompt with a short, fixed vocabulary of arguments: the tab, the ticked items, a note to show and the account that asked. They are built from a closed set of characters and refused rather than escaped if anything else turns up; the ticks travel as base64url. The new window treats them as untrusted: it only selects a tab and ticks boxes that really exist there, and **no argument ever runs a change**. The ordinary window stays open, disabled, until the new one is up and showing, and comes back if you say no or the new window fails to open. Windows briefly reports the new process's console as its main window before Quietpane's own appears, so only a window titled Quietpane counts as ready. Only one Quietpane window is usable at a time.

**Another administrator saying yes.** On a standard account, the administrator who answers the prompt is a different account. The administrator window compares the two by SID (never by name) and then allows only changes whose every part is machine-wide. Anything touching the asking account's own settings is refused before anything is written, and nothing is saved into either account's folders.

**Where it keeps things.**
- `%LOCALAPPDATA%\Quietpane`: your settings, notes, "Leave it for now" choices and restore points for changes made with your own rights. Only the ordinary window replays those restore points. Before writing there, the administrator window checks the folder and file aren't links or junctions and writes through a temporary file.
- `%ProgramData%\Quietpane`: locked when an administrator window first uses it - owner Administrators, inheritance off, and exactly two entries: SYSTEM and Administrators, full control. There is no entry for any other account, not even to read. The lock is read back and checked, and the folder refused if it is anything else. New restore points go into a `machine\points` folder created inside the locked folder, and quarantined files into `machine\quarantine`, which has its own protected lock, so it stays shut even if the main one is ever changed. A quarantined file is copied into a new file there - so it takes the quarantine's lock rather than keeping the permissions it had - checked against its hash, and only then removed from where it was; putting it back works the same way in reverse.
- The ordinary window never reads, lists or writes anything in `%ProgramData%\Quietpane`. Buttons that lead there are always shown, never worked out by looking.

**Records are checked before they are trusted.** Restore points and quarantine records are read with a strict schema: exact fields, exact types, no duplicate or case-varied keys, size limits, a known version. Every registry path, service, task, file and variable in them must be one Quietpane itself changes, and the owner, lock and absence of links are checked on the folder and every file. Anything unexpected refuses the whole record. A quarantined file goes back only to a local, existing folder outside Windows and outside another account's profile, never over an existing file, and only if its hash still matches.

**Undo records and quarantined files from before 2.1 are view only.** Older versions kept them in a folder any account on the PC could change - on a real PC, the old quarantine folder turned out to belong to an ordinary account - so nothing from that time can be shown to be genuine, whatever its lock says today. They are listed by folder name without being opened, and never replayed, put back, moved or deleted by Quietpane. The settings they describe can still be changed back in Windows, and an administrator can copy an old quarantined file out by hand.

**Known limits.**
- Checks on a path and then its use can, in principle, race with a change in between. Quietpane checks immediately before each use, refuses links at every level, creates new files only inside folders it has locked, and never follows a junction when deleting. Closing that window entirely would need a different kind of native call, which Quietpane doesn't add. The largest remaining window is the first time a 2.1 administrator window locks an existing `%ProgramData%\Quietpane` while someone else on the PC is actively racing it.
- Windows does not treat your own ordinary and administrator windows as a security boundary between themselves. Quietpane hardens that, but can't make it one.
- If you run Quietpane from a folder you can write to, anything running as you could change the script before you say yes. When it is installed, Quietpane starts its own copy from `C:\Program Files\Quietpane` instead, which ordinary programs can't change.
- Windows builds, domain policies and account types differ in their default owners, inherited permissions and UAC settings. What has been checked, and on what, is in each release's review.
- Some checks need another account, another PC or another Windows version. They are listed as outstanding until they have been done, never assumed.

For the release-specific engineering review and verification evidence, see the [Quietpane 2.1 Internal Security Engineering Review](docs/security/audits/2026-09-quietpane-2.1-security-audit.md).

## Security reviews

Internal engineering reviews of security-sensitive releases, carried out by the project itself - not independent audits. The index is [docs/security](docs/security/README.md).

| Release | Review | Date |
|---|---|---|
| 2.1 | [Quietpane 2.1 Internal Security Engineering Review](docs/security/audits/2026-09-quietpane-2.1-security-audit.md) | September 2026 |

## Getting a genuine copy
- The only official source is **[github.com/kgntmr/quietpane](https://github.com/kgntmr/quietpane)**, published by KomodoWorks ([komodoworks.com](https://www.komodoworks.com)).
- Right now Quietpane is **only** distributed as plain-text PowerShell scripts in `Quietpane.zip`. **There is no `.exe` version.** Treat any `.exe`, installer or "cracked/pro" version claiming to be Quietpane as fake. If that ever changes, it will be announced here and in the [Code Signing Policy](README.md#code-signing-policy) first.
- Quietpane only ever copies itself to one place, `C:\Program Files\Quietpane`, and only when you add shortcuts or switch on "Start Quietpane when I sign in" in Settings. Program Files is used because ordinary programs can't change it, which matters for something that can run with administrator rights. A Quietpane copy anywhere else, or one you never asked for, isn't ours.
- Because everything is plain text, you can read every line before running it. See [Verify it yourself](README.md#verify-it-yourself).
- The ZIP is built with [`tools/build-release.ps1`](tools/build-release.ps1) and contains the app's files from this repository, unchanged (the tests and build tools are left out). Nothing in it is pre-compiled, and nothing is added.

## Check that your download is genuine
Optional, and takes a minute. Each release lists the **SHA256 checksum** of `Quietpane.zip`, a fingerprint that changes if even one byte of the file is different.

1. Press **Start**, type **PowerShell**, and open **Windows PowerShell**.
2. Paste this line and press **Enter** (it assumes the file is in your Downloads folder):
   ```powershell
   Get-FileHash "$HOME\Downloads\Quietpane.zip"
   ```
3. Compare the **Hash** it shows with the SHA256 on the [release page](https://github.com/kgntmr/quietpane/releases/latest). If they match, your copy is genuine. If they don't, delete it and download it again from the release page.

## Scanning it yourself

You're welcome to, and it's a reasonable thing to do before running anything with administrator rights. Two honest notes about what you'll see:

- **A few engines may flag it, and that doesn't mean it's infected.** Quietpane switches off telemetry services, edits the hosts file and changes startup entries. Those are exactly the actions some scanners score as "riskware", "HackTool" or "PUA" on sight, because malware does them too - the difference is consent, and a scanner can't see consent. A handful of heuristic hits on a debloat script is ordinary; a broad consensus across the big engines would not be, and we'd want to hear about it.
- **Scan the scripts, not just the ZIP.** The files inside are what actually run. Right-click the extracted folder and choose **Scan with Microsoft Defender**, or upload `Quietpane.zip` to a service such as [VirusTotal](https://www.virustotal.com), which unpacks it and reports each file.

Because it's all plain text, the strongest check isn't a scanner at all - it's reading it. [Verify it yourself](README.md#verify-it-yourself) walks through it in four steps, including confirming that the app makes no network connections of any kind.

## If your antivirus or Windows blocked it

Quietpane is **not signed yet**, it can ask for administrator rights, and it changes the kind of settings adware also changes. That combination gets it stopped in three different ways, and each one means something different:

| What you see | What it means | What to do |
|---|---|---|
| **"Windows protected your PC"** (blue box) | SmartScreen hasn't seen enough people run an unsigned app yet. It isn't a detection. | **More info** > **Run anyway**, once you've checked the download (below). |
| **"Smart App Control blocked..."**, or Quietpane says *"can't start on this PC yet"* | Windows 11 on this PC only runs signed apps. There is no way round it for an unsigned app, and there shouldn't be. | Wait for the signed release. **Please don't turn Smart App Control off for Quietpane**: on many PCs it can't be turned back on without resetting Windows. |
| **Your antivirus quarantined or deleted it** | A heuristic - a rule about what files *do*, not a known threat. See [Scanning it yourself](#scanning-it-yourself). | Check the download, then report it to your antivirus as a false positive (below). |

**Never add an exception or turn your protection off because of Quietpane.** If you can't run it with your protection on, wait for the signed release, which is what fixes most of this.

**Check the download first.** Compare its SHA256 with the release page ([how](#check-that-your-download-is-genuine)); if you like, read the code ([Verify it yourself](README.md#verify-it-yourself)).

**Report a false positive.** Every antivirus has a form for this - search for your antivirus's name and "false positive". Attach `Quietpane.zip` from the [release page](https://github.com/kgntmr/quietpane/releases/latest), say it was flagged wrongly, and link to [the source](https://github.com/kgntmr/quietpane). For Microsoft Defender, use the [Microsoft file submission page](https://www.microsoft.com/en-us/wdsi/filesubmission). It helps us if you [tell us](mailto:info@komodoworks.com) which antivirus it was, and the name it gave.

### For the maintainer, with each release

1. Submit `Quietpane.zip` to Microsoft ([file submission](https://www.microsoft.com/en-us/wdsi/filesubmission), as a *software developer*, *incorrectly detected*), before announcing the release.
2. Submit it to each vendor users have reported, through that vendor's own false-positive form.
3. Paste this, with the version and SHA256 filled in:

   > Quietpane VERSION, `Quietpane.zip`, SHA256 `...`. Free, open-source (MIT) Windows privacy tool by KomodoWorks, Dublin. Plain-text PowerShell with no `.exe` or precompiled binary; its small C# blocks ship as readable source and are compiled locally at runtime; full source at https://github.com/kgntmr/quietpane. It changes privacy settings, disables telemetry services, edits the hosts file and can quarantine files - only when the user confirms; most changes can be undone from inside the app. It makes no network connections. We believe this detection is a false positive and are happy to answer questions: info@komodoworks.com.

4. Keep a note of the vendor, the detection name and the reply. Code is never changed to hide from a scanner - if a detection points at something Quietpane genuinely does badly, that gets fixed openly.

**Signing would improve publisher identity and Windows trust signals.** Quietpane currently has no signing certificate. Its September 2026 [SignPath Foundation](README.md#code-signing-policy) application was not approved at this stage because the project does not yet show enough external public-trust and visibility signals. As of 3 October 2026, GitHub Actions jobs are also failing before any workflow steps start, so there is no functioning CI-backed signing path today.
