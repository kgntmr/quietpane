# Quietpane 2.1 - verification evidence

The output behind the figures in the [Quietpane 2.1 Internal Security Engineering Review](../../audits/2026-09-quietpane-2.1-security-audit.md), so you can check them rather than take them on trust. Recorded on the maintainer's test PC (Windows 11 25H2, build 26200) on 30 September and 1 October 2026.

| File | What it shows | SHA256 |
|---|---|---|
| [tests-unelevated.txt](tests-unelevated.txt) | The full test suite without administrator rights: every test by name. 326 passed, 0 failed, 15 skipped (the ones that need administrator rights, EICAR, and one that only runs without Defender). | `2CBCB7F6D17D98046A3D5EA36BA0C9AFF308978FFDD6F34303A36E46D240C7AA` |
| [tests-elevated.txt](tests-elevated.txt) | The same suite with administrator rights: 339 passed, 0 failed, 2 skipped. | `686D687E0929AE57584D447F57929BBED588F18F8548261EDE7B787C463BD3CC` |
| [machine-store-unchanged.txt](machine-store-unchanged.txt) | The real protected folder before and after the elevated run: permissions, sizes and SHA256 of every file. Unchanged. | `E429E03F82710C25990360EC91EA91942F01B71C331F6C72C569B6843757D961` |
| [selftests.txt](selftests.txt) | The window self-test with administrator rights, and without them in light and dark. | `84D6504ED6D9CBF5DF9C163BC57150B919EAA15FB64F4D85A39E3F66A80F3668` |
| [procmon-1-surface.txt](procmon-1-surface.txt) | Process Monitor: start-up, every tab, a change of your own and its Undo. 0 accesses by the ordinary Quietpane. | `1DE5ED638C2C51CF64DEBBCA1066A59BAAFAFAF675251099B33ABB9FFF089682` |
| [procmon-2-watch.txt](procmon-2-watch.txt) | Process Monitor: the sign-in check (-Watch). 0 accesses. | `A8D9DF6B050E092C27B50FC5550335D93C157712367755D6E00662D9D3D0077E` |
| [procmon-3-check.txt](procmon-3-check.txt) | Process Monitor: the in-window Safety scan, to completion. 0 accesses. | `7D7BCE6FE66D988165484AB74E301022467163AC2BDDADB746C50D9DE3E19367` |
| [procmon-4-scan.txt](procmon-4-scan.txt) | Process Monitor: "Safety scan only" (-Scan), to completion. 0 accesses. | `772564FA36BF62EB1169C63EBFB52EEFD7DCF7E808C8B68EB6578DCF99C2EEB7` |

**What was changed before publishing:** the Windows account name, the PC's name, the profile path and real SIDs are replaced with `<user>`, `<PC>` and `<SID>`; the app's own folder is written `<repo>`. Nothing else was edited. The SIDs `S-1-5-21-1111111111-...` in the test output are the suite's own made-up test values.

**What is not here:** the raw Process Monitor captures (several gigabytes, full of machine-specific detail) and the test harness. Each capture file above says exactly how it was filtered and lists every event under `%ProgramData%\Quietpane`, including the harness's own positive-control events, which prove the filter was working.

The UAC checks (a prompt declined; accepted, with the second click, Undo, and both terminal hosts) were done by hand and are recorded in the audit, section 6.5.