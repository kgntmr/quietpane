# Checks a person has to do by hand

Most of Quietpane is covered by `tests\Run-QuietpaneTests.ps1`. A few things cannot be, and this is
the list. Nothing here uses real malware: every file below is a harmless industry test file that
antivirus products agree to detect so people can check their protection works.

**Why these are not automated:** they need a file to arrive from the internet, and Quietpane makes no
network requests at all. Automating them would mean the app downloading something, which would break
the one promise the whole product rests on. So a person opens a browser instead.

Run these after any release that touches the Safety scan.

## 1. EICAR, offline (also covered by `-Live`)

The automated suite already writes the EICAR string into a temp folder and asks Defender to scan it.
Run it as administrator:

    powershell -ExecutionPolicy Bypass -File tests\Run-QuietpaneTests.ps1 -Live

Expected: Defender detects it, Quietpane shows it as **Info**, source **Microsoft Defender**, family
**EICAR test file** - never as Critical, and never as a malware family.

## 2. AMTSO feature checks (browser, a few minutes)

AMTSO (the Anti-Malware Testing Standards Organization) hosts safe feature-check pages at
<https://www.amtso.org/check-desktop-solution/>. Work down the list in a browser, with Microsoft
Defender real-time protection on:

| AMTSO check | What should happen in Windows | Then in Quietpane |
|---|---|---|
| EICAR download over HTTP | Defender blocks the download | Run the check: either nothing to show, or an Info-level EICAR line |
| EICAR download over HTTPS | Defender blocks it too | Same |
| Compressed EICAR (`.zip`) | Defender blocks it | Same |
| Potentially Unwanted Application (PUA) test | Defender flags it as PUA | Shows as **Low**, category unwanted software, with a "leave it or remove it" choice |
| Phishing page test | SmartScreen warns in the browser | Nothing - Quietpane does not look at web pages, and should not claim to |
| Cloud protection test | Defender reacts within a few seconds | Whatever Defender recorded, named as Defender's finding |
| Drive-by download test | Defender blocks it | Same |

What to look for in Quietpane afterwards:

- Every threat name shown is Defender's, with **found by Microsoft Defender** on the card.
- Confidence is **Confirmed** for Defender detections, never for Quietpane's own checks.
- The doughnut's centre number equals the number of findings listed, and clicking a legend row filters
  the list to that severity.
- Nothing is removed, quarantined or deleted unless you click it.

If Defender does not react at all, check whether another antivirus has taken over. Quietpane says so
on the results panel when it happens; that message should appear rather than a clean bill of health.

## 3. The window itself

These need eyes, not assertions:

- **Health tab.** The four tiles change every couple of seconds. Compare the graphics temperature
  and video memory with Task Manager > Performance > GPU: they come from the same place and should
  match. Hover a temperature to see where it comes from.
- **Health pauses.** Switch to another tab, or minimise the window, and Quietpane's own CPU use in
  Task Manager should drop to nothing: it reads nothing until the Health tab is back on screen.
- **Undo is up to date straight away.** Apply something, then open the Undo tab at once: the new
  restore point is at the top, with the right number of changes. Nothing ever shows "0 change(s)".
- **Opening is smooth.** From the Start menu, the window can be dragged the moment it appears - it
  never stops responding while it reads the PC. A Safety scan's "Checking what is reporting home"
  step takes a moment, not a quarter of a minute.
- **Slowing down to cool off.** Under a long, heavy game on a laptop, the processor tile may say it
  is slowing down to cool off. If it appears while the PC is idle and cool, that is a bug.
- **Not shared.** On a PC with no dedicated graphics card or no thermal zone, the tiles say "not
  shared" or "temperature not shared" - never 0 degrees.
- **What's using it.** The programs under the processor and graphics tiles should match the top of
  Task Manager > Processes, sorted by CPU and by GPU. Quietpane lists itself as "Quietpane (this app)".
- **Battery and drive.** On a laptop, the Battery card's "holds N% of what it did when new" should
  match Windows' own report (`powercfg /batteryreport`). The Drive card should say what Windows says
  in Settings > System > Storage > Disks & volumes. Wear and temperature come from the drive itself
  without administrator rights; only Windows' own fallback needs them, and then the row says so.
- **Came back.** Switch one of Quietpane's privacy settings back on yourself in Windows Settings,
  then open Quietpane: Home says one setting came back. "That was me" hides it for good; doing it
  again and choosing "Switch them off again" puts exactly that one setting right, with a restore point.
- **Startup items match Task Manager.** Apps tab > Starts when you sign in should list the same
  things as Task Manager > Startup apps, with the same on/off state. Switch one off in Quietpane and
  Task Manager shows it as Disabled straight away; Undo, and it shows Enabled again. Sign out and
  back in to confirm it really stays quiet.
- **Camera, microphone and location match Settings.** Privacy tab > Who used your camera,
  microphone and location should name the same apps, with the same times, as Settings > Privacy &
  security > Camera (and Microphone, Location) > Recent activity. Open the Windows Camera app: the
  section header says the camera is in use right now. Switch a Store app off in Quietpane and its
  switch in Settings is off straight away; Undo, and it is on again.
- **Where your space went.** Free up space > Look. The drive's used figure should match File Explorer's,
  and "Windows and system files" should be the rest of it. Click into Program Files: every row should
  say where to uninstall rather than offer the Recycle Bin. A folder bigger than the Recycle Bin's
  limit must say "Too big for the bin", never move. Move a small file of your own and check it lands
  in the Recycle Bin, the totals drop, and a restore point appears in Undo.
- **What's talking to the internet.** Privacy > What's talking to the internet right now. Open a
  website and the browser should appear within about five seconds; close everything and the list
  shrinks. Compare it with Resource Monitor > Network > TCP Connections: the same programs, allowing
  for QUIC, which Windows does not list.
- **Start menu and desktop.** Settings > Add to Start menu and desktop. Both shortcuts show the emblem,
  open Quietpane, and right-click > Pin to taskbar gives one taskbar button, not two, while it runs.
  `C:\Program Files\Quietpane` now exists. Close Quietpane, move or rename the folder you unzipped,
  and check the Start menu, desktop and taskbar shortcuts all still open it.
- **Old shortcuts are repaired.** With a shortcut made by 1.10.0 (it opens the unzipped folder), open
  1.11.0 from its folder once. The details log says each shortcut now opens Quietpane's own copy.
- **Starting when you sign in.** Switch on "Start Quietpane when I sign in", sign out and back in. About
  20 seconds later Quietpane is on the taskbar, minimised, without taking the focus, and Windows did
  not ask for administrator rights. Task Manager shows it using no processor time until you click it;
  then it opens and looks at the PC as usual. The Safety scan lists the task as "Quietpane's own
  sign-in start".
- **Told when things come back.** Switch on "Also tell me if Windows switches things back on" too. Switch
  one of your startup items back on in Task Manager, sign out and back in. Quietpane's taskbar icon
  shows a small amber "1", and hovering it says "1 thing switched itself back on"; opening it shows
  the Welcome back panel. "That was me" (or switching it off again) clears the badge. With nothing
  back on, the icon has no badge at all. Switch it off and the next sign-in doesn't check.
- **What signing in costs.** Apps > Starts when you sign in. Each program that is running says how much
  memory it is using and how long after sign-in it started; the heaviest is at the top, and the line
  above adds them up. Open something heavy (a browser), press F5, and its figure goes up. A program
  that isn't running says so rather than guessing. With a recent full restart, the "Windows timed your
  last restart at N seconds" line appears with its date; point at it for the breakdown. Compare a
  couple of the figures with Task Manager > Startup apps and Details - they should agree.
- **Watch this session.** Health > Watch this session, then go and use the PC for a few minutes with
  something heavy running, and minimise Quietpane. Come back: the card names the worst of it and the
  peaks match what Task Manager showed at the time. Put the PC to sleep and wake it: the gap is
  reported as a stretch that went unwatched, not drawn through. Press Stop and the summary stays on
  screen; close Quietpane and reopen it, and the record is gone, as it says it will be. While it is
  watching and you are on another tab, Quietpane's own processor use in Task Manager stays near zero.
- **Alerts, once each.** While watching, run something heavy until the processor is very hot for five
  minutes: the status line says so, the line appears in amber at the top of the session card, and it
  never says it a second time however long the heat lasts. Minimise Quietpane first and the taskbar
  icon carries a badge; restore the window and the badge clears. With a "came back" badge already
  showing, that one stays - it is about a choice you made.
- **The rings and big numbers.** Open Health and start something heavy: the processor and graphics
  rings fill where Task Manager's figures climb, at the same moment, and turn amber or red only when
  the words under them say "hot" or "very hot". Point at a number after a minute: it says how high it
  went in the last two minutes. Make the window as narrow as it goes: the list on the right moves
  underneath, nothing is cut off, and the tabs stay on one row (their icons step aside).
- **The Health list against Windows' own figures.** With Task Manager > Performance open beside it:
  - Processor: cores and threads (Task Manager calls threads "logical processors") and the speed.
  - Graphics: the graphics clock and video memory clock. Task Manager doesn't show these; on an NVIDIA
    card compare `nvidia-smi --query-gpu=clocks.gr,clocks.mem --format=csv` - they should match to
    within a moment's change. On built-in graphics the clock is lower and there is no temperature row.
  - Graphics fan: shown only if the driver reports one. On most laptops it isn't there, and that is right.
  - Memory: type, speed (MT/s) and "Slots used" match Task Manager > Memory.
  - Drive: reading and writing speed follow Task Manager > Disk while you copy a big folder.
  - Network: Wi-Fi or wired speed follows Task Manager > Wi-Fi / Ethernet while something downloads.
    Connect a VPN, or run WSL: the figure must not double.
  - Fan speed: "not shared by the maker" on a PC whose maker keeps it to its own app. It must never be a
    number that doesn't move.
  - Power plan: the one in Control Panel > Power Options.
  - This PC: the maker and model on the sticker, Windows as Settings > System > About says, each screen.
- **Laptop and desktop.** On a desktop there is no Battery box at all, rather than one that says nothing.
  On a laptop the battery's charge, whether it is plugged in, the watts, and how much it holds.
- **Two graphics cards.** On a gaming laptop the Graphics box has a heading for each card, and the ring
  shows the one with its own memory, with "Also <the other one>: N%" under it.
- **Celsius or Fahrenheit.** Settings > Temperatures > F: every temperature on Health, in the session
  card and in a saved session report changes at once; close and reopen Quietpane and it is still F.
  `%LOCALAPPDATA%\Quietpane\temperature.txt` holds one letter. Back to C the same way.
- **Switches say how things are.** Settings > Start Quietpane when I sign in: the switch moves only once
  the task is made. Turn Narrator on, Tab to it and flip it with the Space bar: the same happens, and
  Task Scheduler has the task. Where making the task fails (a work PC whose policy blocks it, say), the
  switch stays off and says why.
- **The session timeline.** While watching, the strip under the headline grows from the left. Run
  something heavy: the columns get taller and darker, and the thin row underneath fills in while the
  processor is held back. Put the PC to sleep and wake it: that stretch is blank, not stretched over.
  Squint, or turn the screen to greyscale - the heights alone should still tell you where the bad spell
  was, and every colour in it is named in the legend.
- **The session report.** After a few minutes of watching, press "Save it to my Desktop". One
  `Quietpane-Session-*.html` appears there and opens in your browser: the figures match the card, the
  alerts carry the times they were raised, and the gaps are named. Turn the wifi off and open it again
  - it looks exactly the same, because it fetches nothing. Open it in dark mode and it should still be
  readable.
- **How it has been holding up.** The score matches Reliability Monitor (run `perfmon /rel`) and the
  date under it matches the last point on its graph. The programs named match what that report lists
  as stopped working - and Windows Update entries, which fill most of that report, are not counted.
  On a PC where Windows has kept no score, the card says "Not scored" rather than showing 0.
- **The three extra vitals.** Under the tiles, compare "memory promised to programs" with Task Manager
  > Performance > Memory > Committed, the processor speed with its Speed figure, and disk busy with
  Task Manager's disk % - they come from the same place and should agree. On battery, the battery card
  shows watts and a time left; plugged in and full, it says neither rather than showing 0 W.
- **Worth clearing first.** Free up space > Look. The suggestions appear above the folder list, the ones
  you can act on first. Check a couple by hand: an installer it names really is in Downloads, and its
  date matches File Explorer's "Date modified". "Show me which" lists them; "Move N to the Recycle Bin"
  asks first, then moves exactly those, the drive is added up again, and the Undo tab has one new
  restore point with the right number of changes. Everything moved is in the Recycle Bin and restores
  to where it was. Your previous Windows and the Recycle Bin are named with their size and no button.
- **Browser add-ons.** Privacy > Your browser add-ons. The list matches `edge://extensions` and
  `brave://extensions` (and Chrome's, and Firefox's Add-ons page) name for name, with the same on/off
  state, and the ones that "read and change everything on every site you visit" are at the top. Install
  a harmless add-on from the store, press F5, and it appears saying where it came from. Tick it, Apply,
  and the browser shows it greyed out as blocked by an administrator, with "managed by your
  organisation" in the menu; Undo, and it works again within a minute. A Firefox add-on has no tick box
  and says to switch it off in Firefox itself. Nothing in the browser's own folder changes: compare the
  dates on `Secure Preferences` before and after.
- **Short on screen, full underneath.** On Privacy, each setting is one line and one short note. Point
  at one (or Tab to it) and the full explanation appears; Narrator reads the same words. Nothing that
  warns about a side effect is hidden: "Turn off printing" still says "only if you never print".
- **Medium and Low findings can be acted on.** After a Safety scan, a Medium finding with a file behind
  it - unsigned programs, a cracked-software file, a service running from a user folder - has
  Quarantine and Remove it. The unsigned-programs card has buttons on each row, and quarantining one
  row leaves the others alone. A finding about a setting (a proxy, the firewall) has no buttons.
- **Keyboard only.** Put the mouse away. Tab moves through every button, tick box and link with a
  teal outline around the one you're on; Ctrl+Tab changes tab; Space or Enter presses; arrow keys and
  Page Down scroll a page; F5 reads the PC again; Esc closes the choice window, which opens with the
  safest choice already selected.
- **With Narrator.** Ctrl+Win+Enter starts Narrator. Moving through the window, every control is read
  by name (the Safety scan's legend reads like "High: 2 findings - ... Show only these"), and the
  status line is read out as it changes, such as "All done - nothing running".
- **Taking them away.** Untick the box and remove the shortcuts. The task is gone from Task
  Scheduler, and `C:\Program Files\Quietpane` is in the Recycle Bin - straight away if you opened
  Quietpane from the unzipped folder, or a moment after closing it if you opened it from the Start menu.
- **Stop.** Start "Check this PC", press **Stop** after a few seconds. The progress line changes to
  "Stopping as soon as it is safe to...", then the summary says the check was stopped and that
  nothing was changed. No report is written to the Desktop.
- **Stop during a Defender scan.** Same again with "Check and ask Defender to scan". Defender may
  carry on in the background for a while - that is Defender's own scan and is safe to leave.
- **Progress.** While a check runs, the line under the heading shows the step, what it is looking at,
  how many things it has seen and how long it has been going.
- **The summary.** After a check: looked at, found by severity, dealt with, and one next step. Act on
  a finding and the "dealt with" line updates without re-running the check.
- **Quarantine round trip.** Quarantine something, confirm it disappears from its folder, then use
  "Put it back" and confirm it returns to the same place.
- **Preview, Apply, Undo.** On the Privacy tab: Preview changes nothing, Apply writes a restore point,
  and the Undo tab puts it back.
- **Dark mode.** Open a saved report with Windows set to dark mode; the chart and severity colours
  should still be readable.
- **The drive's own figures, on a drive that is not this one.** The Health tab asks the drive itself
  for its temperature, its wear and its hours, and falls back to Windows only where the drive will not
  answer. It has been proved on one NVMe drive, where Windows insisted on a flat 60 C whatever was
  happening and the drive gave a temperature that rose from 45 C to 48 C under a heavy write and fell
  back again. Worth repeating on: a SATA SSD, a spinning hard drive, and a USB or card-reader drive,
  where the right answer may well be "not shared" - which is fine, as long as it says so instead of
  showing a zero or an invented number.
- **A tile with nothing behind it.** On a desktop with no separate graphics card, or a PC with the
  disk counters switched off, every empty tile must read "not shared" rather than 0%.
- **The verdict under real load.** Start something heavy and watch the sentence at the top of the
  Health tab follow it: calm, then working hard, then held back to cool off, and back again.

- **Light and dark, for real.** The self-test switches the window's colours both ways and fakes
  what Windows says, but only a person can flip the real setting. With Quietpane open and Appearance
  on *Match Windows*, change Settings > Personalisation > Colours > *Choose your mode* between Light
  and Dark: within about a second the window follows, and so does its title bar. Then pick *Light*
  under Appearance and flip Windows again - Quietpane must stay light. Close and reopen: the choice
  is remembered. Windows' own controls (tick boxes, scroll bars) keep Windows' look in both themes.

- **Smart App Control, for real.** On a Windows 11 PC with Smart App Control *on* (a fresh
  install, or a test VM - never turn it off and on again on a real PC), double-click *Start
  Quietpane*: the console must explain that the PC only runs signed apps, and must not tell anyone
  to switch Smart App Control off. Repeat once releases are signed: it should then simply start.
- **An update, end to end.** Put a newer `Quietpane.zip`, downloaded through a browser, in
  Downloads. Open the older Quietpane: Home offers it. *Install it* shows the version and SHA256,
  unpacks to `Downloads\Quietpane <version>`, closes, and the new one opens the way a double-click
  would, with your own rights and Windows' downloaded-file checks. Check one unpacked file in
  PowerShell with `Get-Content <file> -Stream Zone.Identifier`: it must say `ZoneId=3`.
- **The old folder after an update.** With shortcuts added in Settings, open the old unzipped folder:
  the newer copy opens instead, once, with no loop.

## 3a. Admin rights, since 2.1

Quietpane opens without administrator rights and asks only for changes that need them. The automated
tests cover the rules; these need real Windows prompts, real accounts, or a tool watching the disk.

**Repeatable checks on the maintainer's PC:** The release-specific review records which of these were actually completed. This checklist describes how to perform them; being listed here does not mean a check has passed for every release or environment.

- **Opening.** Double-click *Start Quietpane*: no permission prompt. Health, add-ons, camera history,
  startup costs and Where your space went all work. Hidden system tasks say "needs admin rights to
  check", Windows' temp folder says its size needs admin rights, and the quarantine and "Changes made
  with admin rights" show a button with the shield.
- **A change of your own.** Tick an HKCU-only privacy item (for example *Turn off ads on the lock screen*),
  Apply: no prompt, and it is done. Undo it: no prompt.
- **A change to Windows.** Tick a service item: the shield appears on Apply. Press it, say **No**:
  nothing changes and the window is usable. Press it again, say **Yes**: Quietpane opens again with
  "(admin)" in its title, on Privacy, with the same ticks and a note - and **nothing has run**. Press
  Apply: it is done.
- **The handover.** With the console host and again with Windows Terminal as the default terminal,
  the first window closes only once the admin window is showing, never while a console flashes up.
  Say No: the first window stays. There is never a moment with two usable windows.
- **A folder with awkward characters.** Unzip to `...\Desktop\Quiet pane & 100% (1)\` and repeat the
  shield flow: the tab and ticks arrive intact. If you can, repeat under a folder with non-English
  letters.
- **Safety scan only.** No prompt, a useful report, and a short list of what an administrator would
  also see. "Check and ask Defender to scan" works without admin rights.
- **Moving from 2.0.** The first ordinary window uses the default appearance and degrees. After the
  first admin window, Light/Dark and C/F from 2.0 carry over - unless they were already set in 2.1.
- **Older undo records.** In the admin window, points made by 2.0 are listed as made by an older
  Quietpane, with no Undo. A hash of `%ProgramData%\Quietpane\restore` before and after is the same.
- **The locked folders.** After the first admin window, `Get-Acl` on `%ProgramData%\Quietpane` and on
  `machine\quarantine` shows owner Administrators, inheritance off, and only SYSTEM and
  Administrators. Files quarantined by 2.0 (in the old `quarantine` folder) are listed by name as
  kept by an older Quietpane, with no buttons, and are left exactly where they are. From an ordinary PowerShell, listing either folder or reading any `meta.json` is
  denied. In the admin window, quarantine a harmless test file you made in `%TEMP%`, then list, put
  back and delete it.
- **Sign-in start.** An existing task set to run with highest privileges becomes limited the next time
  an admin window opens. After the next sign-in, Task Manager's *Elevated* column says **No** for it.
- **Brand extras.** On the Apps tab, compare each extra's shield with where it is registered. One
  registered for your account whose uninstaller is known to run as you has no shield; one that needs
  admin, or that Quietpane can't classify, has it; every machine-wide one has it. Uninstall nothing.
- **Nothing touches the admin-only folder (release blocker).** Run Process Monitor with two filters:
  the unelevated Quietpane `powershell.exe` (Task Manager's *Elevated* column says No), and a path
  beginning with `C:\ProgramData\Quietpane`. Go through first start, every tab, Settings, a report, a
  user-only Apply and its Undo, the Undo tab with its two shielded buttons, a `-Watch` run, a `-Scan`
  run, and a shielded click answered **No**. Expected: **0 events**. Anything else blocks the release.
  - *Filter on the path, not only the prefix:* use **Path contains** `ProgramData\Quietpane` plus the
    8.3 short spellings on that PC (`dir /x C:\` and `dir /x C:\ProgramData` show them, for example
    `PROGRA~3` and `QUIETP~1`), keep System in the capture, and tick **Drop Filtered Events** so a long
    scan stays small. Note each Quietpane process's PID and its *Elevated* column as it starts.
  - *Prove the filter works:* from an administrator PowerShell, run
    `Test-Path C:\ProgramData\Quietpane\machine` once at the start and once at the end. Those events
    must appear; if they don't, the capture proves nothing.
  - *Count only the ordinary Quietpane.* System (PID 4), Defender and any elevated process are
    recorded but are outside the rule.
  - The Safety scan runs much slower while Process Monitor watches (about 35 minutes on the
    maintainer's PC). Leave its window open until the report appears.
  - Last recorded run: 30 September 2026, 2.1 release candidate - see
    [the 2.1 audit, section 7](security/audits/2026-09-quietpane-2.1-security-audit.md#7-protected-machine-store-isolation).

**Needs another account or PC:**

- **A standard account, with a different administrator answering the prompt.** The admin window says
  it is running as the other account. A batch of the user's own settings is refused; a mixed batch is
  refused before anything is written (the registry values and the audit log are unchanged); a batch
  of machine-wide changes only runs. Nothing appears in the administrator's own profile: no
  `%LOCALAPPDATA%\Quietpane`, no task, no shortcut.
- **A Microsoft account and a local account:** the sign-in start opens Quietpane without admin rights
  in the right session.
- **Windows 10:** the shield on the buttons is Windows' own shield.
- **A PC with `%ProgramData%\CleanMyPC\restore` points:** listed in the admin window, never replayed.
- **A Windows user name with non-English letters:** the shield flow and the per-account folder.
## 4. What is deliberately not tested

- Live ransomware, remote access tools, stealers or loaders. Never, in any environment.
- Anything that asks Quietpane to prove a PC is clean. It cannot, and the product says so.
