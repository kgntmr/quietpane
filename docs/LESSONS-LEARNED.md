# Lessons learned

These notes come from cleaning a real gaming/development laptop by hand before this tool existed. Each lesson shaped how the tool behaves.

## 1. How the adware survived: a scheduled task that re-creates itself
The PC opened random `cmd` windows. The visible cause was a startup entry:

```
HKCU\...\CurrentVersion\Run  "User" = cmd.exe /c start www.<adware-site>.org
```

Deleting that entry alone wouldn't have worked. A scheduled task, also innocently named **`User`**, ran at every boot with highest privileges and simply wrote the entry back:

```
cmd.exe /c reg add HKCU\...\CurrentVersion\Run /v User /t REG_SZ /d "cmd.exe /c start www.<adware-site>.org" /f
```

**Lesson:** always check scheduled tasks for `reg add ...\Run`, `start http...` and hidden scripts, not just Run keys. The Scan tab does this.

## 2. Timestamps tell you what installed it
The malicious task's file (`C:\Windows\System32\Tasks\User`) was created at **22:46:29**. An `AppData\Local\<GameName>` folder was created at **22:46:38**, nine seconds later. The adware came bundled with a **cracked game**, and the task appeared at the same moment the game installed.

**Lesson:** for every suspicious task, the Scan lists folders created within 3 minutes of it. Cracked games and "free" repacks are one of the most common ways adware and password stealers get onto a PC. If you find one, also change important passwords and turn on two-factor authentication, just in case.

## 3. Cracked games leave clear traces
Crack folders (`NoDVD`, `CODEX-RUNE`, `Anadius`...), loader DLLs such as `winmm.dll` next to the game, and game executables whose **Authenticode signature is broken** (`HashMismatch`: signed by the publisher, but modified since) are strong signals. The Scan reports them. It doesn't delete them, because it's your software.

A side effect people notice: tools like NVIDIA App list the same game several times, once for each copy of the executable in the crack folders.

## NVIDIA App telemetry cannot be deleted
This one cost a reinstall.

1. `rundll32 NVI2.DLL,UninstallPackage NvTelemetry`, the command many older guides recommend, **also uninstalled NVIDIA App**, its containers, the overlay and virtual audio. In NVIDIA App 11 those packages depend on the telemetry package, and NVIDIA's installer removes dependents automatically. Older guides were written for GeForce Experience, where telemetry was a separate package.
2. After reinstalling, deleting only the telemetry plugin folder (`NvTelemetry\plugin`) stopped the **NvContainerLocalSystem** service from starting. A junction (`NvContainer\plugins\LocalSystem\NvTelemetry`) points at that folder, and the container quits when the target is missing.
3. Putting an empty folder there got the container running again, but NVIDIA App's user container then failed with *"Transition to Initializing state for mandatory plugin NvAccount failed"*. Game optimisation and driver updates stopped working.
4. Restoring the plugin fixed everything.

**Lesson:** in NVIDIA App 11 the telemetry plugin is a hard dependency. The safe approach, and what this tool does, is to **block only the telemetry servers** (`events.telemetry.data.nvidia.com`, `feedbacks.telemetry.data.nvidia.com`, `telemetry.gfe.nvidia.com`, `events.gfe.nvidia.com`, `prod.otel.kaizen.nvidia.com`, survey and experiment endpoints) and set NVIDIA's opt-out flags. Servers used for driver downloads, game optimisation and sign-in stay reachable.

## Other things worth knowing
- **Microsoft Edge can't be uninstalled outside the EEA.** Its setup exits with code 93. You can stop it auto-starting and set its telemetry policies, but keep **WebView2**, because many apps draw their windows with it.
- **Don't use the global "background apps off" switch.** Packaged (Store/MSIX) apps, including many chat, music and AI desktop apps, lose notifications and background work.
- **MSI Center modules each have their own uninstaller** (`MSI Center\<Module>\unins000.exe`). That's how to remove AI Engine or Gaming Gear without removing MSI Center. Leaving a module's reason blank in the first-run wizard stops it pre-selecting extra features.
- **Intel Driver & Support Assistant quietly installs the "Intel Computing Improvement Program"**, which is Intel telemetry and runs about 400 MB of background services. Uninstall it separately, or check for driver updates through your laptop maker's app or Windows Update instead.
- **Windows re-creates some tip/"SoftLanding" tasks** after updates. They stay harmless while the tips settings are off. Just run the tool again after big updates.
- **Clicking inside a PowerShell console window pauses the script.** The title shows "Select". Press Esc or Enter to resume.
- **Windows paths have a 260-character limit.** Scripts stored in very deep folders can fail to start for no obvious reason. Keep the tool in a short path such as `C:\Tools\quietpane`.
- **Show first, then decide.** An age rule must not make a large new crash dump invisible. Quietpane reports total and eligible bytes separately, leaves young items unticked, and checks project protection again before applying.
- **Recycle Bin first, exact confirmation when it cannot fit.** Moving files to the Recycle Bin is the normal path. An oversized item is never silently deleted: the person must select it, see its exact path and size, and confirm permanent deletion twice.
