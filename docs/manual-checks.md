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
  in Settings > System > Storage > Disks & volumes. Wear and temperature need Quietpane's usual
  administrator rights; without them the card just says "Healthy".
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
- **Start menu and desktop.** About > Add to Start menu and desktop. Both shortcuts show the emblem,
  open Quietpane, and right-click > Pin to taskbar gives one taskbar button, not two, while it runs.
  `C:\Program Files\Quietpane` now exists. Close Quietpane, move or rename the folder you unzipped,
  and check the Start menu, desktop and taskbar shortcuts all still open it.
- **Old shortcuts are repaired.** With a shortcut made by 1.10.0 (it opens the unzipped folder), open
  1.11.0 from its folder once. The details log says each shortcut now opens Quietpane's own copy.
- **Starting when you sign in.** Tick "Start Quietpane when I sign in", sign out and back in. About
  20 seconds later Quietpane is on the taskbar, minimised, without taking the focus, and Windows did
  not ask for administrator rights. Task Manager shows it using no processor time until you click it;
  then it opens and looks at the PC as usual. The Safety scan lists the task as "Quietpane's own
  sign-in start".
- **Told when things come back.** Tick "Also tell me if Windows switches things back on" too. Switch
  one of your startup items back on in Task Manager, sign out and back in. Quietpane's taskbar icon
  shows a small amber "1", and hovering it says "1 thing switched itself back on"; opening it shows
  the Welcome back panel. "That was me" (or switching it off again) clears the badge. With nothing
  back on, the icon has no badge at all. Untick the box and the next sign-in doesn't check.
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
- **The trend under each tile.** Open Health and leave it a minute: a line grows under each number with
  a dot on the newest reading. Start something heavy and the line climbs where Task Manager's graph
  climbs, at the same moment. Switch tabs for five minutes and come back - the line starts again rather
  than drawing a straight line across the time nobody was reading.
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

## 4. What is deliberately not tested

- Live ransomware, remote access tools, stealers or loaders. Never, in any environment.
- Anything that asks Quietpane to prove a PC is clean. It cannot, and the product says so.
