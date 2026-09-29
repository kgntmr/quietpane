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

## Getting a genuine copy
- The only official source is **[github.com/kgntmr/quietpane](https://github.com/kgntmr/quietpane)**, published by KomodoWorks ([komodoworks.com](https://www.komodoworks.com)).
- Right now Quietpane is **only** distributed as plain-text PowerShell scripts in `Quietpane.zip`. **There is no `.exe` version.** Treat any `.exe`, installer or "cracked/pro" version claiming to be Quietpane as fake. If that ever changes, it will be announced here and in the [Code Signing Policy](README.md#code-signing-policy) first.
- Quietpane only ever copies itself to one place, `C:\Program Files\Quietpane`, and only when you add shortcuts or tick "Start Quietpane when I sign in" in About. Program Files is used because ordinary programs can't change it, which matters for something that starts with administrator rights. A Quietpane copy anywhere else, or one you never asked for, isn't ours.
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

Quietpane is **not signed yet**, it asks for administrator rights, and it changes the kind of settings adware also changes. That combination gets it stopped in three different ways, and each one means something different:

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

   > Quietpane VERSION, `Quietpane.zip`, SHA256 `...`. Free, open-source (MIT) Windows privacy tool by KomodoWorks, Dublin. Plain-text PowerShell with no executable; full source at https://github.com/kgntmr/quietpane. It changes privacy settings, disables telemetry services, edits the hosts file and can quarantine files - only when the user confirms; most changes can be undone from inside the app. It makes no network connections. We believe this detection is a false positive and are happy to answer questions: info@komodoworks.com.

4. Keep a note of the vendor, the detection name and the reply. Code is never changed to hide from a scanner - if a detection points at something Quietpane genuinely does badly, that gets fixed openly.

**Signing is the real fix.** A signature from the [SignPath Foundation](README.md#code-signing-policy) certificate is the first thing SmartScreen and Smart App Control look for; SmartScreen also builds trust in a signed app as more people run it. Two things stand in the way: the SignPath application (pending), and GitHub Actions, which SignPath signs from and which is currently unavailable on this account.
