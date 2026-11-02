# Quietpane 2.3.0

Quietpane now shows storage before deciding what is old enough to clear. Visible and eligible bytes are
separate, so a new multi-gigabyte crash dump no longer disappears behind the 24-hour safety rule.

## What changed

- Free up space is grouped into temporary files, application and automation caches, Docker storage,
  and Windows system storage.
- Young files are visible but unticked. The largest 20 items and everything at least 100 MB are shown.
- Repository markers and folders protected in Settings exclude project data. Protection is checked again
  immediately before an action.
- Docker containers, images, build cache and named volumes are separate choices. Active dependencies are
  refused, Compose ownership is shown, and named volumes are never preselected.
- Docker virtual-disk size is advisory only; Quietpane does not stop WSL or compact the disk.
- Apps now shows a neutral Windows inventory, using reported sizes and registered uninstallers.
- The hibernation row shows the hibernation file and explains the effect on Hibernate and Fast Startup.
- Files still go to the Recycle Bin when they fit. An oversized item needs two exact confirmations before
  permanent deletion.

Quietpane remains offline, has no telemetry, and supports Windows 10 and 11 with Windows PowerShell 5.1.
