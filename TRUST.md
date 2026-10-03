# Can I trust Quietpane?

**Last checked: 2 October 2026**

You should not have to trust Quietpane just because its website or README says it is safe.

Quietpane is built so you can check the important claims yourself: the source is readable, the tests are published, the limits are written down, and the release has a hash you can compare.

## The short version

Quietpane:

- runs without administrator rights by default;
- asks for administrator rights only when a specific action needs them;
- does not have accounts, ads, analytics or telemetry;
- does not make background network requests;
- shows changes before making them;
- keeps restore points for changes that can be undone;
- labels the few actions that cannot be undone;
- ships as readable PowerShell and source C# - no `.exe` or precompiled binary;
- leaves Defender, SmartScreen, the firewall and Windows Update enabled.

It can ask Microsoft Defender to scan or remove one of Defender's own detections, but only when you choose that action.

## The current download

The current public release is **Quietpane v2.1.0**, published on 1 October 2026.

Source commit:

`aebdc33b2842ae9dd6d0f1d67710dd95177f7bb5`

SHA256 of the published `Quietpane.zip`:

`C7126A133C6476C76C1A950ED9BB34D26BC01EA3D8466F048574A0CBD064FD87`

You can compare that hash with the ZIP you downloaded. [SECURITY.md](SECURITY.md#check-that-your-download-is-genuine) explains how.

The code in the repository has moved on since that release, mainly with documentation and CI changes. The version number above refers to the ZIP currently published on the Releases page.

## What the tests actually say

For Quietpane 2.1, the full test suite was run on the maintainer's Windows 11 PC both normally and with administrator rights.

Without administrator rights:

**326 passed, 0 failed, 15 skipped**

With administrator rights:

**339 passed, 0 failed, 2 skipped**

The skipped tests are named in the published output. They are not counted as passes.

You can read the actual results:

- [Tests without administrator rights](docs/security/evidence/2.1/tests-unelevated.txt)
- [Tests with administrator rights](docs/security/evidence/2.1/tests-elevated.txt)
- [Window self-tests](docs/security/evidence/2.1/selftests.txt)
- [Check that the real protected Quietpane folder stayed unchanged during testing](docs/security/evidence/2.1/machine-store-unchanged.txt)

## What was checked on a real Windows PC

The 2.1 security work was not only tested with fake inputs.

Real Windows checks included:

- Quietpane opening without an administrator prompt;
- saying **No** to the UAC prompt and confirming nothing changed;
- saying **Yes** and confirming Quietpane still waits for a second click before making the requested change;
- the handoff working with Windows Terminal and Windows Console Host;
- the protected Quietpane data folder having administrator-only permissions;
- putting a harmless file into Quietpane's quarantine and restoring it;
- checking file hashes during quarantine and restore;
- watching Quietpane with Microsoft Process Monitor.

For the protected folder under `%ProgramData%\Quietpane`, the recorded Process Monitor runs found:

**0 accesses from the ordinary, non-admin Quietpane process.**

The method, what was tested and what was not tested are written in the [2.1 Internal Security Engineering Review](docs/security/audits/2026-09-quietpane-2.1-security-audit.md).

## Does Quietpane send anything away?

Quietpane itself makes no background network requests.

It has no Quietpane account, advertising, analytics, crash reporting or telemetry service.

When you press a link such as **Look for a newer version**, Quietpane tells Windows to open the page in your normal browser. Your browser then goes online as normal. Quietpane does not secretly download an update itself.

You can also check this yourself with the source search and Resource Monitor steps in [README.md](README.md#verify-it-yourself).

## What still is not verified

There are things we have **not** proved yet, and they should stay visible.

### Windows 10

Quietpane supports Windows 10 and 11, but the new 2.1 administrator-rights handoff has not yet been re-checked on a real Windows 10 PC.

### Another administrator account

The automated tests cover different Windows account IDs and make sure another administrator cannot silently change the wrong user's settings.

The full real-PC test where a standard user asks a different administrator to approve UAC is still outstanding.

### Other account setups

Real-PC checks are still outstanding for:

- both a Microsoft account and a local Windows account using start-at-sign-in;
- a Windows username containing non-English letters;
- another PC with old CleanMyPC / pre-2.1 restore records.

### Code signing

Quietpane is **not digitally signed yet**.

Windows can therefore show **Unknown publisher**. Quietpane's September 2026 SignPath Foundation application was not approved at this stage because the project does not yet have enough external public-trust and visibility signals for the Foundation program. There is currently no active signing certificate.

Do not turn off SmartScreen, Smart App Control or antivirus protection just to run Quietpane.

### The release ZIP

The public v2.1.0 ZIP was built on the maintainer's PC and uploaded manually.

GitHub Actions can build a ZIP too, but the published v2.1.0 download is **not** that CI artifact.

The ZIP build is also not byte-for-byte reproducible yet because ZIP timestamps can differ between builds.

Those are things we want to improve, not things we pretend are already solved.

### Independent review

The security review in this repository was carried out by the Quietpane project itself.

It is **not** an independent security audit, certification or penetration test.

## How the repository is protected

The `main` branch is protected.

Changes to it must go through a pull request. Force pushes and deleting `main` are blocked, and unresolved review conversations block merging.

There is no bypass account in the branch rule.

Quietpane also has a GitHub Actions test workflow. It is configured to run on:

- pushes to `main`;
- pull requests targeting `main`;
- manual runs.

At the moment, GitHub Actions is disabled at the account level, so those hosted checks cannot currently act as a merge gate. Local Windows tests are being used until Actions is enabled again.

## Why publish all of this?

Because Quietpane can change Windows settings and can sometimes ask for administrator rights.

A green badge, a nice website or the words "open source" are not enough on their own.

The useful questions are:

- Can I read what it does?
- Can I see what it will change before it changes it?
- Can I see the test results?
- Are the things that were not tested also listed?
- Can I verify the file I downloaded?
- Is the project clear about what is still unfinished?

That is the standard Quietpane is aiming for.

If something in this page does not match the code or the published evidence, treat that as a bug and report it.
