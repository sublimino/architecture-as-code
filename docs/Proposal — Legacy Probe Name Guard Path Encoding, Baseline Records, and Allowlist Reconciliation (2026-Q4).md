# Proposal — Legacy Probe Name Guard Path Encoding, Baseline Records, and Allowlist Reconciliation (2026-Q4)

## 1. Executive Summary

This proposal resolves scanning failures in the old probe name guard.
The scanner failed on path encodings, baseline records, and live stream contracts.
Git path quoting prevented decision record exclusions from matching files with non-ASCII characters.
Tracked directory symlinks caused ripgrep to traverse already-scanned module paths.
Baseline test logs lacked directory-level recognition in the decision record pattern.
Recent commits established the live in-kernel eBPF stream contract without updating guard allowlists.
We reconcile the scanner, baseline record patterns, and allowlist fixtures.
All guard tests pass cleanly.

## 2. Problem Statement

The test suite `test/old-probe-name-guard.bats` failed on real repository scans.
Investigation revealed four distinct failure mechanisms.
First, `git ls-files` defaulted to quoting paths containing non-ASCII symbols.
Proposals with em-dashes appeared as quoted strings with octal escape sequences.
The regular expression engine failed to match these quoted strings against the records pattern.
Second, a tracked symlink pointed to the legacy module directory.
When passed as a path argument, ripgrep recursed into the symlinked directory.
This caused duplicate findings under an unallowlisted alias path.
Third, baseline run evidence stored raw test logs in `docs/slsi-p0-baseline/raw`.
The lint records pattern only matched the top-level markdown document.
Finally, recent commits integrated the live in-kernel eBPF telemetry stream.
These commits introduced intentional occurrences of the probe stream name.
The guard allowlist fixtures lacked corresponding entries for these live contracts.

## 3. Implementation Details

We configure git to disable path quoting in `scripts/check-old-probe-name.sh`.
We pass `-c core.quotepath=false` to every `git ls-files` call in the scanner script.
We skip directory symlinks before invoking ripgrep on tracked contents.
This prevents ripgrep from recursing into symlink targets.
We update the records pattern in `scripts/docs-lint.sh`.
The updated pattern matches `docs/slsi-p0-baseline/` and `docs/amxd-p0-baseline/`.
We update `test/fixtures/old-probe-name-allowlist.txt` with entries for the live telemetry stream.
We update `test/fixtures/old-probe-name-pending-p3-1.txt` with the new signal ingest collector files.

## 4. Verification Record

- We verified `scripts/check-old-probe-name.sh --root .` reports zero findings across 6,736 files.
- We verified all 15 tests pass in `bats test/old-probe-name-guard.bats`.
- We verified all 7 tests pass in `bats test/docs-index-sync.bats`.
- We verified `scripts/docs-lint.sh` passes on `docs/README.md` and this proposal.
