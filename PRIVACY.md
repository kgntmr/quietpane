# Privacy Policy: Quietpane

**Last updated: 23 September 2026**

Quietpane is free, open-source software developed by **KomodoWorks**, an independent technology studio in Dublin, Ireland ([komodoworks.com](https://www.komodoworks.com)).
Contact: **info@komodoworks.com**

## The short version

- **Quietpane collects no personal data.** It has no accounts, analytics, telemetry, crash reporting, advertising, tracking, cookies or fingerprinting.
- **It makes no network connections.** It never "phones home", checks for updates in the background, downloads anything or uploads anything.
- **Everything it reads stays on your PC.** KomodoWorks never receives it and has no way to see it.
- **Nothing is sold or shared**, because nothing is collected.

You don't have to take our word for it. See [Verify it yourself](README.md#verify-it-yourself).

## What the app looks at on your computer, and why

The app runs only on your PC, only when you start it, and only does what you click.

| Feature | What it reads or changes | Where results are kept |
|---|---|---|
| **Scan** (read-only) | Startup entries, scheduled tasks, services, selected registry values, the hosts file, proxy and DNS settings, names and digital signatures of program files in user folders, browser **extension manifests** and **notification permission lists**, Microsoft Defender and firewall status, the running-process list, folder sizes | An HTML report saved on **your** Desktop |
| **Microsoft Defender detections** (part of the scan) | Defender's own list of what it has found on this PC: threat names, file paths, dates and status, read through Windows' built-in Defender commands. Quietpane also works out the SHA256 of a detected file so you can look it up yourself. **Nothing is sent to Microsoft by Quietpane, and nothing is sent to us.** | Shown on screen and in the report on your Desktop |
| **Acting on a threat** | Asks Defender to remove what Defender found, quarantines a file, moves it to the Recycle Bin, deletes it when you choose that, or records that you left it alone | Quarantined files live in `%ProgramData%\Quietpane\quarantine\`, locked to administrators, with a small `meta.json` holding the original path, size, times and SHA256 so they can be put back. A line per action goes to `%ProgramData%\Quietpane\audit.log`, and allowed items to `allowed.json`. Leaving something alone is Quietpane's own note: it never creates a Defender exclusion. |
| **Telemetry tab** | Your PC's maker and graphics chip, the list of installed programs, services and scheduled tasks, to recognise brand software | Shown on screen only |
| **Apps tab: what starts when you sign in** | The programs set to start at sign-in (the usual Run entries, the Startup folders and Store apps), with each program's name and publisher from its own file details | Shown on screen only |
| **Privacy tab: what's talking to the internet** (only while that section is open) | Windows' own list of connections open right now: the program, its process, and the address and port at the other end. Names for those addresses come from the list of addresses Windows has already looked up (its DNS cache), and the names of Windows services from Windows itself. **Quietpane makes no network requests: nothing is looked up online, and no address is sent anywhere.** | Shown on screen, refreshed every 5 seconds while you are looking, and nothing at all when the section is closed. **None of it is saved.** |
| **Free up space: where your space went** (only when you press Look) | The names, sizes and dates of folders and files on the drive you pick - never their contents, which are not opened - plus the list of installed programs Windows keeps, so a game or program can be named rather than offered for deletion. For "Worth clearing first" it also reads the names, sizes and dates in your Downloads and Desktop folders, and the size of your previous Windows and your Recycle Bin. | Shown on screen only. If you move something to the Recycle Bin, that is recorded in a restore point like any other change. |
| **Start menu and desktop shortcuts, and starting when you sign in** (only when you choose them in About) | Nothing | Two small shortcut files in your own Start menu and desktop folders; if you tick it, one task in Task Scheduler, **Quietpane (KomodoWorks)**, that opens Quietpane when you sign in; and a copy of the app in `C:\Program Files\Quietpane` for both to open, so moving the folder you unzipped can't break them. The copy is the app's own files only - none of your data. Taking both away in About removes all of it, and the copy goes to your Recycle Bin. |
| **Privacy tab: who used your camera, microphone and location** | Windows' own record of which apps and programs used them and when (the one behind Settings > Privacy & security), each app's allow/deny setting, and the names of those apps from the Start menu and from each program's file details | Shown on screen only. Nothing about it is saved. |
| **Privacy, Telemetry, Apps** (only when you click Apply) | The settings, services, tasks, apps, startup items, camera/microphone/location permissions and hosts-file entries you ticked, and any brand extra you chose to uninstall (using its own uninstaller). Switching a startup item off writes the same small on/off marker Task Manager does; switching an app off for the camera, microphone or location writes the same "Deny" that Settings does. | Restore points and logs in `%ProgramData%\Quietpane\restore\` on your PC. These hold the previous values, so Undo can put them back. |
| **Clean up space** (only when you click Apply) | The folders you ticked | Files are moved to **your Recycle Bin** |
| **Home screen** | Free space on your system drive | Shown on screen. Totals of what the app has freed are kept in `%ProgramData%\Quietpane\totals.json` (two numbers, a count of runs and the date of the last one). None of it leaves your PC. |
| **Health tab** (only while it's open) | How busy the processor, graphics card and memory are, how much video memory is in use, and the names of the programs using them most, all from Windows performance counters. Temperatures from Windows' thermal sensor and from your graphics driver, asked through a short C# block that's compiled on your PC from the readable source in `src/Quietpane.psm1`. On a laptop: the battery's charge, and how much it holds compared with new, from Windows' own battery report. That report is written to a temporary file, read, and deleted straight away. The drive Windows runs from: Windows' verdict on it, plus the drive's own temperature, wear, hours and total written, asked of the drive directly. That question is read-only: the drive is opened with no read or write rights at all, only enough to ask it about itself, and nothing on it is opened or altered. Also how much memory Windows has promised to programs, how much of its speed the processor is being allowed, how busy the drive is, and - on a laptop - how many watts the battery says it is giving or taking. | Shown on screen: live figures every 2 seconds, battery and drive every 5 minutes, and nothing at all when the tab is closed. The last 60 readings are held in the window to draw the trend under each tile, and go when you close it. **None of it is saved.** |
| **Health tab: how it has been holding up** | Windows' own reliability record: its stability score (the one behind Reliability Monitor), and, from your Windows event log, which programs stopped working or stopped responding in the last 30 days, how many times the PC stopped without warning, and any blue screens. Names of programs only - never what you were doing in them. Windows Update and installer entries are not read. | Shown on screen only. Nothing about it is saved, and nothing is sent anywhere. |
| **Health tab: "Watch this session"** (only after you press it) | The same readings as above and nothing more, kept while you work so the peaks can be shown at the end. It carries on while Quietpane is minimised, about every 10 seconds, which is the point of it. | **In this window's memory only.** Nothing is written to disk, nothing is installed and no task is scheduled: closing Quietpane ends the watch and forgets the record. The one exception is **Save it to my Desktop**, which you press: that writes the session up as one HTML page on your Desktop (`Quietpane-Session-*.html`). It holds what is described here and nothing else, makes no network requests, and is yours to keep or delete. |
| **Privacy tab: your browser add-ons** | Each browser's own files, on this PC only: the folder an add-on was unpacked into, its `manifest.json` (which lists what it may do) and the browser's settings file (which says whether it is on and where it came from). For Firefox, its `extensions.json`. **No add-on is opened or run, nothing is looked up online, and none of those files is written to.** | Shown on screen, and named in a scan report if you run one. Nothing else is saved. |
| **Switching a browser add-on off** (only when you tick one and press Apply) | Writes the add-on's id into `HKCU\SOFTWARE\Policies\<browser>\ExtensionInstallBlocklist` - the same setting a workplace uses, under your own account only. The browser then refuses to load that add-on and says an administrator blocked it. Nothing is removed from your browser, and no browser file is touched. | A restore point in `%ProgramData%\Quietpane\restore\`, so Undo takes the policy away again and the add-on works as before |
| **Apps tab: what signing in costs** | Which programs are running now, how much memory each is using and when it started, plus what Windows itself recorded about your last full restart (its own Diagnostics-Performance log, which needs administrator rights to read) | Shown on screen only. Nothing about it is saved, and nothing is sent anywhere. |
| **"Came back" note** | Which of Quietpane's settings are switched off, which unneeded apps are present, which startup items are off, and the Windows version | `%ProgramData%\Quietpane\quiet-note.json`, so Home can tell you when an update switched something back on - and, if you tick "Also tell me if Windows switches things back on" in About, so the check just after you sign in can put a badge on the taskbar icon. That check reads the same things as opening Quietpane does, and nothing more. The note holds setting names, app names and startup entries (which include program names), and nothing else. Delete it any time; it starts afresh. |
| **Welcome notice** | Nothing | `%ProgramData%\Quietpane\welcome-accepted.txt`: one line with the date you accepted the first-run notice and the app version, so it isn't shown again. |

**What the scan does not read:** your browsing history, passwords, cookies, emails, messages, documents or the contents of web pages.

**Scan reports can contain personal information**, for example your Windows username inside folder paths, or the names of programs and browser extensions you use. They exist only on your PC. **Review a report before you share it with anyone**, including us.

## Legal basis (GDPR)

All processing happens locally on your own device, under your control, for your own purposes, and none of it is transmitted to us. KomodoWorks therefore does **not** act as a data controller or processor for anything the app reads on your computer. We can't access, view, copy or delete data on your PC.

You can remove everything the app has stored at any time:
- **Scan reports and session reports:** delete `Quietpane-Report-*.html` and `Quietpane-Session-*.html` from your Desktop.
- **Everything else it keeps** (restore points and logs, the audit log, the quarantine, and the small note files above): delete the folder `%ProgramData%\Quietpane`, and `%ProgramData%\CleanMyPC` if you used the app under its former name. Do this once you're sure you won't need Undo. Anything in the quarantine is deleted with it, and deleting that part needs administrator rights.
- **The app itself:** if you added shortcuts or the sign-in start, take them away in About first (that sends Quietpane's copy in Program Files to the Recycle Bin too). Then delete the folder you extracted it to. There is no installer and nothing else to remove.

## When you leave the app

- **Links.** If you click "KomodoWorks.com" or an email link, your own browser or email program opens it. That is a normal website visit or email, covered by the [KomodoWorks website privacy policy](https://komodoworks.com/en/privacy). The app adds **no tracking parameters** to these links.
- **Downloading the app from GitHub** is subject to the [GitHub Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement). We receive no personal information about who downloads it.
- **If you email us** (a question, a bug report), we use your email address and message only to reply. We keep them only as long as needed, as described in the website privacy policy. Please don't send scan reports unless we ask, and remove anything personal first.

## Your rights

For any personal data you send us by email, you have the rights set out in the GDPR: access, rectification, erasure, restriction, objection and portability. Contact **info@komodoworks.com**. You can also complain to the **Irish Data Protection Commission** ([dataprotection.ie](https://www.dataprotection.ie)) or to the data protection authority in your own country.

## Children

The app collects no data from anyone, including children.

## Changes to this policy

If this policy changes, the date at the top changes, and the full history is visible in the GitHub repository. A future version will **not** start collecting data quietly. If that ever changed, it would be stated clearly at the top of this document and in the release notes before the release.
