# Quietpane trust and verification status

**Last verified: 2 October 2026**

Quietpane is designed so its safety and privacy claims can be inspected rather than taken on trust. This page is the short, current status. The detailed reasoning and raw/cleaned evidence are linked below.

## Current release

| Item | Status |
|---|---|
| Release | **v2.1.0**, published 1 October 2026 |
| Release source | `aebdc33b2842ae9dd6d0f1d67710dd95177f7bb5` |
| Download | `Quietpane.zip` from this repository's Releases page |
| SHA256 | `C7126A133C6476C76C1A950ED9BB34D26BC01EA3D8466F048574A0CBD064FD87` |
| Windows publisher signature | **Not yet signed** - SignPath application pending |
| Release build provenance | **Manual** - the published ZIP is built on the maintainer's PC, not yet promoted from the CI artifact |
| Reproducible ZIP | **Not yet** - ZIP entry timestamps currently prevent byte-for-byte identical rebuilds |
| Independent security audit | **No** |
| Project security review | **Published internal engineering review with evidence and limitations** |

The release tag points directly to the source commit above. Check the ZIP hash before running it; instructions are in [SECURITY.md](SECURITY.md#check-that-your-download-is-genuine).

## What has been verified

### Automated tests

The v2.1 release candidate was tested on the maintainer's Windows 11 PC in both privilege modes:

| Run | Passed | Failed | Skipped |
|---|---:|---:|---:|
| Without administrator rights | **326** | **0** | 15 |
| With administrator rights | **339** | **0** | 2 |

The published output contains every test by name:

- [Unelevated test output](docs/security/evidence/2.1/tests-unelevated.txt)
- [Elevated test output](docs/security/evidence/2.1/tests-elevated.txt)
- [Window self-tests](docs/security/evidence/2.1/selftests.txt)
- [Protected-store before/after evidence](docs/security/evidence/2.1/machine-store-unchanged.txt)

### Real Windows security checks

The 2.1 review records real Windows checks for:

- ordinary launch without administrator rights;
- a UAC prompt declined, with no change made;
- a UAC prompt accepted, with the requested change still waiting for a second explicit click;
- handoff through both Windows Terminal and Windows Console Host;
- protected machine-store ACLs;
- quarantine round trips and hash verification;
- Process Monitor captures covering the ordinary app, sign-in watch and safety scan.

For the protected machine store, the recorded Process Monitor captures found **0 accesses from the ordinary Quietpane process tree**. The capture method, positive controls and cleaned event summaries are published in the [2.1 internal security engineering review](docs/security/audits/2026-09-quietpane-2.1-security-audit.md) and its [evidence](docs/security/evidence/2.1/README.md).

### Privacy and network behavior

Quietpane contains no account, analytics, advertising or telemetry client. Its documented update check opens GitHub in your normal browser only after you ask; Quietpane itself does not download an update or make a background network request.

The README includes a source search and a Resource Monitor check so this can be verified on another PC: [Verify it yourself](README.md#verify-it-yourself).

## Repository controls

The default branch, `main`, is protected by the active **Protect Main** ruleset:

- pull requests are required;
- force pushes are blocked;
- deletion is blocked;
- review conversations must be resolved;
- there is no bypass actor.

The test workflow is configured to run on pushes to `main`, pull requests targeting `main`, and manual runs. As of 2 October 2026, GitHub Actions is disabled at the account level, so the workflow cannot currently provide a green merge gate. A required status check should be added only after Actions is re-enabled and a genuine successful run exists.

## Known limits and unfinished verification

These are deliberately listed rather than inferred as passing:

- **Windows 10:** supported, but the new 2.1 shield/UAC handoff has not yet been re-verified on a real Windows 10 PC.
- **Different administrator account:** automated SID/account tests pass, but the full real-Windows flow with a standard account and a different administrator answering UAC is still outstanding.
- **Microsoft-account/local-account sign-in start:** still needs a second-account real-Windows check.
- **Non-English Windows user name:** still needs a real-Windows handoff/storage check.
- **Pre-2.1 / CleanMyPC restore records:** protected by the new design and never replayed, but another-PC visual coverage remains outstanding.
- **Code signing:** releases currently show Unknown publisher.
- **Release provenance:** the public ZIP is not yet the exact CI artifact.
- **Reproducibility:** identical source does not yet guarantee an identical ZIP hash.
- **Independent review:** the published review was performed by the project itself, not an external auditor or penetration tester.

The complete list is maintained in [the 2.1 review](docs/security/audits/2026-09-quietpane-2.1-security-audit.md#9-outstanding-verification) and [manual checks](docs/manual-checks.md).

## What Quietpane means by "trust"

Quietpane does not ask a user to accept a single security badge or promise. The intended chain is:

1. **Readable source** - PowerShell and the small runtime-compiled C# blocks are shipped as source.
2. **Explicit behavior** - changes are previewed and irreversible actions are labelled.
3. **Automated verification** - functional and adversarial security tests are published.
4. **Real-machine verification** - UAC, ACL and Process Monitor checks are recorded.
5. **Known limits** - unverified environments and design limitations are published.
6. **Repository controls** - protected `main` and PR-based changes.
7. **Next:** green required CI, CI-built releases, reproducible archives and publisher signing.

If a claim on this page conflicts with the implementation or evidence, treat that as a bug and report it.
