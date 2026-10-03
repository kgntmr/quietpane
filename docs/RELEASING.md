# Releasing Quietpane

Quietpane releases are prepared from a reviewed commit already contained in `main`. The public download must come from GitHub Actions, not from a ZIP built on a maintainer's PC.

## Before the tag

1. Finish the release scope and update `src/Quietpane.psm1` so `$script:AppVersion` is the version being released.
2. Run the normal pre-merge review and merge the release work to `main`.
3. Run the proportionate local verification required for the change. Do not create the tag while a known release-blocking check is failing.

## Create the version tag

Create an existing tag in the form `vX.Y.Z` on the exact `main` commit to release, then push that tag. The tag version must match `$script:AppVersion`.

Do not attach a locally built `Quietpane.zip` to a GitHub Release.

## Run the Release workflow

From GitHub Actions, run **Release** and enter the existing version tag.

The workflow:

- reuses `.github/workflows/tests.yml` against that exact tag;
- runs the full Windows checks and source-format gate;
- builds `Quietpane.zip` with `tools/build-release.ps1`;
- fails if rebuilding after changing staged file timestamps changes the ZIP hash;
- downloads the checked Actions artifact rather than rebuilding it in the publishing job;
- verifies `Quietpane.zip.sha256` against the downloaded ZIP;
- writes `PROVENANCE.txt` with the tag, commit, workflow URL and SHA256;
- creates or updates a **draft** GitHub Release and uploads those three files.

The workflow refuses a tag that is not a `vX.Y.Z` tag, is not contained in `main`, or does not match `AppVersion`. It also refuses to overwrite an already-published release.

## Review the draft

Before publishing:

1. Check the tag and commit in `PROVENANCE.txt`.
2. Check the SHA256 in `Quietpane.zip.sha256` matches the ZIP.
3. Review the release notes and known limitations.
4. Download the draft asset and perform any release-specific manual checks required by `docs/manual-checks.md`.
5. Publish the draft only after those checks are complete.

Publishing is deliberately a human action. The workflow creates and updates drafts; it does not make a release public.

## Current limitation

As of 3 October 2026, GitHub Actions jobs are failing before any workflow steps start. The release workflow is therefore implemented but cannot be demonstrated end to end until Actions can run again. The public v2.1.0 ZIP predates this workflow and was built locally; `TRUST.md` records that explicitly.
