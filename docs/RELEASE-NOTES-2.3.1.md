# Quietpane 2.3.1

This patch release fixes the first-run experience of the new storage and application inventory in 2.3.0.

## What changed

- Free up space now selects only real reclaimable entries and measures Recycle Bin capacity without
  requiring administrator-only volume access.
- Protected files and folders are visible in Settings and Free up space. Multiple files can be selected
  together, folders can be added repeatedly, and saved protection is applied to every later scan.
- Storage findings refresh when visible files are removed or changed, when the tab is reopened, and
  periodically while the tab remains open.
- The Free up space and Settings screens use shorter, essential wording.
- Installed apps are read from Windows again on every fresh state scan, so removed applications do not
  remain in the Apps list for the lifetime of a background Quietpane process.

Quietpane remains offline, has no telemetry, and supports Windows 10 and 11 with Windows PowerShell 5.1.
