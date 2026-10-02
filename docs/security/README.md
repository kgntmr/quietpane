# Quietpane security documentation

Quietpane is a Windows privacy and cleanup tool that can ask for administrator rights, so how it uses them is written down in full. The documentation is split three ways:

| Document | What it is | Changes when |
|---|---|---|
| [SECURITY.md](../../SECURITY.md) | The current security architecture - how administrator rights, the UAC prompt, your own and the PC's state are handled - its known limits, and how to report a vulnerability | The design changes |
| [Release reviews](#audits) | Internal release-specific engineering reviews: what risks were found in a security-sensitive release, what changed, how it was verified, and what is still outstanding | A major security-sensitive release ships |
| [docs/manual-checks.md](../manual-checks.md) | The checks a person has to do by hand on real Windows, as a repeatable procedure | A check is added or changed |

The architecture says what Quietpane is designed to do. An audit is the evidence for one release: which parts were checked, how, and which were not.

## Audits

| Release | Review | Date |
|---|---|---|
| 2.1 | [Quietpane 2.1 Internal Security Engineering Review](audits/2026-09-quietpane-2.1-security-audit.md) - and its [verification evidence](evidence/2.1/README.md) | September 2026 |

These reports are internal engineering reviews, carried out by the project itself, unless a report explicitly says otherwise. None is an independent audit, a certification or a penetration test.

Later reviews are added under [`docs/security/audits/`](audits/), named `YYYY-MM-quietpane-<version>-security-audit.md`, and listed here and in [SECURITY.md](../../SECURITY.md#security-reviews).
