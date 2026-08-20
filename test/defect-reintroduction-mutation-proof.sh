#!/usr/bin/env bash
# defect-reintroduction-mutation-proof.sh — re-introduce SHIPPED defects, one at
# a time, and prove a NAMED test goes red for the right reason.
#
# ─── What this is, and how it differs from the other proofs here ────────────
#
# The other test/*-mutation-proof.sh harnesses ask "can this guard fail?" — they
# mutate a guard's subject and check the guard notices. This one asks the
# narrower and more uncomfortable question: take the defects this repository
# ACTUALLY SHIPPED and later fixed, put each one back exactly as it was, and see
# whether the suite that now claims to cover it says so.
#
# The distinction matters because a guard can be provably capable of failing and
# still be pointed slightly to one side of the defect it was written for. Two of
# the six below were, and both were found this way rather than by mutation
# testing the guards in the abstract:
#
#   D3  the payload guard false positive — NOTHING failed. The covering test
#       drives a fixture repo that does not contain the tracked files the
#       widened pattern collides with, so it cannot observe the defect. Fixed by
#       test/terraform-demo-driver.bats "DEMODRIVER PAYLOADGUARD …".
#   D6  the vacuous assertions — the detector works and its message is the best
#       in the tree, but `make gcp-tf-validate` never ran it. Fixed by
#       test/terraform-vacuity-gate.bats.
#
# Every defect below is real. Each cites the behaviour it caused.
#
# ─── Scope, and why this does not run whole suites ──────────────────────────
#
# Each defect runs only the tests named as its catchers, via `bats --filter`.
# Running six full sweeps would add ~25 minutes to a gate that already takes
# thirteen. The full sweep was done once, by hand, during the run that produced
# this file — that is where the two holes came from, and it is the right shape
# for an investigation rather than for a gate.
#
# The cost of narrowing is stated rather than hidden: this harness proves the
# NAMED tests catch the NAMED defects. It cannot discover that some OTHER suite
# has quietly become the only thing standing between the repo and one of them.
#
# ─── Safety, per terraform/CONTRACT.md §7b ─────────────────────────────────
#
#   * The REAL files are mutated. A fixture copy would prove only that the copy
#     was mutated.
#   * Pristine copies live OUTSIDE the repository at a DETERMINISTIC path, so a
#     SIGKILL that outruns the trap is recoverable by hand.
#   * `git checkout` is never used to restore. It silently reverts uncommitted
#     work elsewhere in the same directory.
#   * Every mutation is ASSERTED to have applied, by SHA-256 AND by content. A
#     sed whose pattern stopped matching exits 0 and changes nothing, and the
#     run that follows then tests correct code and passes — proving the opposite
#     of what it claims. Python string replacement with an explicit occurrence
#     count is used instead of sed wherever the target contains `|`, because an
#     unescaped pipe in a sed expression is a syntax error that reads exactly
#     like "the guard did not fire".
#   * A sentinel naming the mutation, the file, the backup path and this PID is
#     dropped while the tree is dirty. Finding one at startup is a REFUSAL. It is
#     never repaired: a harness that quietly fixes a half-restored tree is the
#     same shape as the dead guards this repo keeps finding.
#   * Restoration is verified by SHA-256 and the hashes are printed.
#
# The filename is the registration. GCP_TF_PROOFS is `$(wildcard
# test/*-mutation-proof.sh)`, so this is in the gate the moment it lands and
# must NOT also be named in a variable — a hand-registered proof runs twice, and
# a duplicate run is green, just slower.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DRIVER="scripts/gcp-tf/demo-up.sh"
INSTALLER="scripts/ci/install-ci-tools.sh"
MAKEFILE="Makefile"
TS_BATS="test/terraform-tailscale-access.bats"

SENTINEL="${REPO_ROOT}/.defect-reintroduction-mutation-in-progress"
SAFE="${TMPDIR:-/tmp}/osramp-defect-reintroduction-proof"

BATS_BIN="${BATS_BIN:-$(command -v bats || true)}"

red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn() { printf '\033[1;32m%s\033[0m\n' "$*"; }
say() { printf '%s\n' "$*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

if [ -z "$BATS_BIN" ]; then
	red "CANNOT RUN: bats is not on PATH. This is NOT a pass."
	exit 2
fi
command -v python3 >/dev/null 2>&1 || {
	red "CANNOT RUN: python3 is not on PATH; the mutations need it. This is NOT a pass."
	exit 2
}

# ── Refuse, never repair ────────────────────────────────────────────────────
if [ -e "$SENTINEL" ]; then
	red "REFUSING TO START: a previous run left a sentinel."
	say ""
	sed 's/^/    /' "$SENTINEL" 2>/dev/null
	say ""
	say "  That run was killed while a REAL file was mutated. The working tree may"
	say "  still hold a deliberately broken driver, installer, Makefile or bats"
	say "  suite. This harness will NOT repair it — auto-repair is how a broken"
	say "  component ships green, and you would have no way to tell a repaired"
	say "  tree from one that was never damaged."
	say ""
	say "  If the PID above is still alive, a harness is MID-RUN and this refusal"
	say "  is correct; wait for it. If it is gone, restore each file from the"
	say "  backup path by hand, confirm with 'git status' and the SHA-256 values"
	say "  recorded above, delete the sentinel, then re-run."
	exit 2
fi

mkdir -p "$SAFE"
rm -f "${SAFE:?}"/*.pristine

declare -A PRISTINE_SHA=()
for f in "$DRIVER" "$INSTALLER" "$MAKEFILE" "$TS_BATS"; do
	[ -f "$f" ] || {
		red "CANNOT RUN: ${f} is missing. Nothing below would be measurable."
		exit 2
	}
	cp "$f" "${SAFE}/$(basename "$f").pristine"
	PRISTINE_SHA["$f"]="$(sha "$f")"
done

restore_all() {
	local f
	for f in "$DRIVER" "$INSTALLER" "$MAKEFILE" "$TS_BATS"; do
		cp "${SAFE}/$(basename "$f").pristine" "$f"
	done
	rm -f "$SENTINEL"
}
trap restore_all EXIT

FINDINGS=0
CURRENT=""

sentinel_write() { # <description> <file>
	{
		printf 'defect-reintroduction-mutation-proof.sh is MID-RUN or was KILLED.\n'
		printf 'pid:      %s\n' "$$"
		printf 'started:  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		printf 'mutation: %s\n' "$1"
		printf 'file:     %s\n' "$2"
		printf 'backups:  %s\n' "$SAFE"
		printf 'restore each file from <backups>/<basename>.pristine, expected SHA-256:\n'
		local f
		for f in "$DRIVER" "$INSTALLER" "$MAKEFILE" "$TS_BATS"; do
			printf '  %s  %s\n' "${PRISTINE_SHA[$f]}" "$f"
		done
	} >"$SENTINEL"
}

# apply <file> <description> <python-transform>
#
# The transform receives the file contents as `s` and must set `out`. It is
# expected to assert its own anchors: an anchor that has drifted must stop the
# harness, not silently produce an unmutated file.
apply() {
	local file="$1" desc="$2" code="$3"
	sentinel_write "$desc" "$file"
	local before after
	before="$(sha "$file")"
	FILE="$file" python3 -c "
import os,sys
p=os.environ['FILE']
s=open(p).read()
out=None
$code
assert out is not None, 'transform set no output'
assert out != s, 'transform produced an identical file'
open(p,'w').write(out)
" || {
		red "  THE MUTATION DID NOT APPLY (${desc})."
		say "         Its anchors have drifted. Every verdict for this defect would be"
		say "         vacuous, so this is a REFUSAL, not a pass."
		FINDINGS=$((FINDINGS + 1))
		return 1
	}
	after="$(sha "$file")"
	if [ "$before" = "$after" ]; then
		red "  ${file} IS BYTE-IDENTICAL AFTER MUTATION (${desc}). Not a pass."
		FINDINGS=$((FINDINGS + 1))
		return 1
	fi
	return 0
}

unmutate() { cp "${SAFE}/$(basename "$1").pristine" "$1"; }

LAST_OUT="${SAFE}/last-bats-output.txt"

# run_named <file> <exact test name> -> PASS | FAIL | NOMATCH
#
# A --filter that matches NOTHING exits 0 with no tests, which is
# indistinguishable from a pass and is the exact defect this repository keeps
# finding. NOMATCH is reported separately and always counts as a finding.
run_named() {
	local file="$1" name="$2" rc=0
	"$BATS_BIN" --filter "$(printf '%s' "$name" | sed 's/[][\.*^$(){}?+|/]/\\&/g')" \
		"$file" >"$LAST_OUT" 2>&1 || rc=$?
	if ! grep -qE '^(ok|not ok) ' "$LAST_OUT"; then
		printf 'NOMATCH'
		return 0
	fi
	[ "$rc" -eq 0 ] && printf 'PASS' || printf 'FAIL'
}

# expect_red <file> <test name>
expect_red() {
	local file="$1" name="$2" r
	r="$(run_named "$file" "$name")"
	case "$r" in
	FAIL)
		grn "  RED    ${name}"
		grep -E '^#' "$LAST_OUT" | grep -vE '^# \(in test file|^#   ' | head -3 |
			sed 's/^# /           /' || true
		;;
	NOMATCH)
		red "  NOMATCH  ${name}"
		red "           No test by that name in ${file}. It was renamed or deleted, and"
		red "           this defect is now uncovered. A filter that matches nothing exits 0."
		FINDINGS=$((FINDINGS + 1))
		;;
	*)
		red "  GREEN  ${name}"
		red "         HOLE: the defect is present and this test did not notice."
		FINDINGS=$((FINDINGS + 1))
		;;
	esac
}

# expect_green <file> <test name> — the baseline half. A test that is red on a
# clean tree makes its red-on-mutation meaningless.
expect_green() {
	local file="$1" name="$2" r
	r="$(run_named "$file" "$name")"
	if [ "$r" = "PASS" ]; then
		grn "  green  ${name}"
	else
		red "  ${r}  ${name}"
		red "         not green on a CLEAN tree; nothing measured against it is meaningful"
		FINDINGS=$((FINDINGS + 1))
	fi
}

defect() {
	CURRENT="$1"
	say ""
	say "════ ${CURRENT}"
	say ""
}

# ═══════════════════════════════════════════════════════════════════════════
# D1  The env-var prefix mismatch.
#
# demo-up.sh exported ten SL_DEMO_* names; demo-pipeline.sh reads DEMO_*. Zero
# consumers, all ten fell back to defaults. Reports were written to
# ${HOME}/demo-reports while collection packaged /opt/signalloom/reports (verdict
# ABORTED), and DEMO_SOURCE_COMMIT never arrived, so the VM stamped its own
# throwaway git SHA and the STALE guard could never match on any run.
#
# The mutation is WHOLESALE, matching what shipped. Renaming two of the ten would
# model a typo and would report UNPROVEN against a defect that was total.
# ═══════════════════════════════════════════════════════════════════════════
defect "D1  the env-var prefix mismatch (SL_DEMO_* sent, DEMO_* read)"
D1_TESTS_FILE="test/terraform-env-contract.bats"
D1_TEST="the driver exports no name under a prefix the pipeline cannot read"
D1_TEST2="every variable demo-up.sh exports is read by demo-pipeline.sh"
expect_green "$D1_TESTS_FILE" "$D1_TEST"
expect_green "$D1_TESTS_FILE" "$D1_TEST2"
if apply "$DRIVER" "rename the nine exported DEMO_* names to SL_DEMO_*" '
import re
i = s.index("printf -v envs \x27DEMO_ENV=%q")
j = s.index("\n", i)
line = s[i:j]
assert line.count("DEMO_") == 9, "expected 9 exported names, found %d" % line.count("DEMO_")
out = s[:i] + line.replace("DEMO_", "SL_DEMO_") + s[j:]
'; then
	expect_red "$D1_TESTS_FILE" "$D1_TEST"
	expect_red "$D1_TESTS_FILE" "$D1_TEST2"
fi
unmutate "$DRIVER"

# ═══════════════════════════════════════════════════════════════════════════
# D2  The cached SUDO boolean.
#
# install-ci-tools.sh sampled `[ -w "${BIN}" ] || SUDO="sudo"` ONCE at line 27,
# and the property it samples is mutated by its own caller on BOTH sides of the
# call (demo-pipeline.sh `chmod a+w` / `chmod go-w`, both `2>/dev/null || true`,
# so a failed chmod is indistinguishable from a successful one). /usr/local/bin's
# OWNER also varies between identical rebuilds — root:root on one,
# 1001:google-sudoers on the next — so no amount of care at line 27 produces an
# answer that stays true. Measured consequence: bun and uv failed to install,
# each logged one ERROR line, and the pipeline carried on for twenty minutes
# before aborting for an unrelated reason.
#
# The mutation keeps bin_place's NAME and every call site, and removes only what
# the fix added: escalation at write time, and verification of the result. A
# mutation that also reverted the call sites would be caught by a shape test
# ("no tool is placed into BIN except through bin_place") and would prove
# nothing about whether the BEHAVIOURAL regression is covered.
# ═══════════════════════════════════════════════════════════════════════════
defect "D2  the cached SUDO boolean (privilege decided once, at script start)"
D2_FILE="test/terraform-toolchain-pins.bats"
D2_TEST="bin_place escalates when the cached probe was wrong, and verifies the result"
expect_green "$D2_FILE" "$D2_TEST"
if apply "$INSTALLER" "revert bin_place to the cached-SUDO shape: no escalation, no verify" '
start = s.index("bin_place() { # src dest [mode]")
end = s.index("\n}\n", start) + 3
old = s[start:end]
assert "sudo -n install" in old, "bin_place no longer escalates; anchor drift"
assert "not executable after" in old, "bin_place no longer verifies; anchor drift"
new = ("bin_place() { # src dest [mode]\n"
       "  local src=\"$1\" dest=\"$2\" mode=\"${3:-0755}\"\n"
       "  ${SUDO} rm -f \"$dest\"\n"
       "  ${SUDO} install -m \"$mode\" \"$src\" \"$dest\"\n"
       "}\n")
out = s[:start] + new + s[end:]
'; then
	expect_red "$D2_FILE" "$D2_TEST"
fi
unmutate "$INSTALLER"

# ═══════════════════════════════════════════════════════════════════════════
# D3  The payload guard false positive.  <- was a HOLE
#
# A bare `\.terraform` matched `.terraform.lock.hcl`, tracked on purpose (four of
# them), and `\.tfvars$` matched `*.example.tfvars`, also tracked on purpose. The
# guard REFUSES rather than filters, so `make gcp-tf-demo-up` could not build at
# all, with a message telling the operator to untrack the provider pins.
#
# When this defect was re-introduced on 2026-08-20 the entire bats suite stayed
# green in 247s. The covering test drives make_repo's fixture, whose .gitignore
# mirrors the real repo's EXCLUSIONS but which contains none of the tracked,
# legitimate, collision-shaped files. The test added below reads the real tree.
# ═══════════════════════════════════════════════════════════════════════════
defect "D3  the payload guard false positive (refuses this repo's own tracked files)"
D3_FILE="test/terraform-demo-driver.bats"
D3_TEST="DEMODRIVER PAYLOADGUARD the exclusion pattern does not fire on THIS repo's tracked files"
D3_OLD="DEMODRIVER the payload carries the code and excludes every secret"
expect_green "$D3_FILE" "$D3_TEST"
if apply "$DRIVER" "widen .terraform[/-] to .terraform and drop the example-tfvars exemption" '
# Located by SUBSTRING, never by restating the regex. A literal copy of that
# pattern would have to survive bash single-quoting, python source escaping and
# the regex itself; the first draft over-escaped by one layer and the anchor
# assertion below caught it, which is the only reason this comment exists rather
# than a silently unmutated file and a green verdict.
lines = s.split("\n")
inc = [i for i, l in enumerate(lines) if "grep -E " in l and "terraform[/-]" in l]
assert len(inc) == 1, "expected exactly 1 exclusion pipeline line, found %d" % len(inc)
i = inc[0]
lines[i] = lines[i].replace("terraform[/-]", "terraform")
j = i + 1
assert "grep -vE" in lines[j], "the exemption line does not follow the include line: %r" % lines[j]
assert "example" in lines[j] and "tfvars" in lines[j], "the exemption line is not the example exemption: %r" % lines[j]
del lines[j]
out = "\n".join(lines)
'; then
	expect_red "$D3_FILE" "$D3_TEST"
	# The historical record, asserted rather than remembered. If this ever goes
	# RED the fixture has gained the colliding files and the note above is stale.
	r="$(run_named "$D3_FILE" "$D3_OLD")"
	if [ "$r" = "PASS" ]; then
		say "  (control) the fixture-driven test stayed green, as it did when this"
		say "            defect shipped — its fixture cannot observe the collision."
	else
		red "  (control) ${r}  ${D3_OLD}"
		red "            This USED to stay green. If the fixture now carries a tracked"
		red "            lock file the note above is stale — update it, do not delete it."
		FINDINGS=$((FINDINGS + 1))
	fi
fi
unmutate "$DRIVER"

# ═══════════════════════════════════════════════════════════════════════════
# D4  The tailnet name drift.
#
# Without `ts-logout` before a destroy the corpse holds the MagicDNS name for
# 47-100 minutes, so the rebuild is handed a numerically SUFFIXED variant of it
# and the demo URL moves.
#
# The suffixed name is described rather than written, and that is not squeamish-
# ness. test/terraform-ts-stable-node-name.bats "ANTI-TEST: no suite pins the
# drifted name as an expectation" greps all of test/ for that literal, because
# the tempting fix for this defect is to assert equality against the drifted name
# and thereby encode the bug as the contract. It builds its needle with printf so
# it cannot match its own source; it cannot tell prose from an expectation, and
# the first draft of this comment turned the gate red by quoting the name. That
# is the guard working. Describe the shape, do not spell it.
#
# The whole recipe line is deleted, which is what its absence looks like. Note
# that `ts-logout` still appears four times in the Makefile afterwards, three of
# them in the comment block directly above the deleted line: a guard that greps
# the file for the string is satisfied by the prose explaining it.
# ═══════════════════════════════════════════════════════════════════════════
defect "D4  the tailnet name drift (no ts-logout before destroy)"
D4_FILE="test/terraform-ts-stable-node-name.bats"
D4_TEST="gcp-tf-destroy releases the tailnet name BEFORE terraform destroy"
D4_TEST2="the destroy path FORCES, so the guard cannot silently skip the logout"
expect_green "$D4_FILE" "$D4_TEST"
expect_green "$D4_FILE" "$D4_TEST2"
if apply "$MAKEFILE" "delete the ts-logout --force line from the destroy recipe" '
tgt = "\t-@$(GCP_TF_DEMO_ENVIRONMENT) \x27$(GCP_TF_DEMO_SCRIPT)\x27 ts-logout --force\n"
assert s.count(tgt) == 1, "expected exactly 1 destroy-recipe logout line, found %d" % s.count(tgt)
out = s.replace(tgt, "")
assert "ts-logout" in out, "the string vanished entirely; the mutation is not the shipped defect"
'; then
	expect_red "$D4_FILE" "$D4_TEST"
	expect_red "$D4_FILE" "$D4_TEST2"
fi
unmutate "$MAKEFILE"

# ═══════════════════════════════════════════════════════════════════════════
# D5  ts-logout wiping a live serve config.
#
# `tailscale logout` removes serve and funnel. Without the refusal, a logout on a
# live node brings it back correctly named, resolving through MagicDNS, online,
# and serving NOTHING — and every check short of fetching the URL calls that
# healthy. Measured on demo-2.
#
# Only the guard block is removed; the logout itself and the --force plumbing are
# left alone, so the single variable is whether the refusal exists.
# ═══════════════════════════════════════════════════════════════════════════
defect "D5  ts-logout wiping a live serve config (no refusal on a serving node)"
D5_FILE="test/terraform-ts-stable-node-name.bats"
D5_TEST="ts-logout REFUSES when the node is currently serving"
D5_TEST2="an unreadable serve status REFUSES rather than assuming there is none"
expect_green "$D5_FILE" "$D5_TEST"
expect_green "$D5_FILE" "$D5_TEST2"
if apply "$DRIVER" "remove the serve-state refusal from cmd_ts_logout" '
start = s.index("    # THE GUARD. Checked before the logout, never repaired after it.\n")
end = s.index("\n    if remote_run \x27sudo tailscale logout\x27; then", start)
old = s[start:end]
assert "REFUSING to log out" in old, "anchor drift: the refusal text moved"
assert "ts_serve_state" in old, "anchor drift: the serve probe moved"
assert old.count("TS_LOGOUT_REFUSED") == 2, "expected both refusal arms, found %d" % old.count("TS_LOGOUT_REFUSED")
out = s[:start] + s[end+1:]
'; then
	expect_red "$D5_FILE" "$D5_TEST"
	expect_red "$D5_FILE" "$D5_TEST2"
fi
unmutate "$DRIVER"

# ═══════════════════════════════════════════════════════════════════════════
# D6  The vacuous assertions.  <- was a HOLE at the GATE
#
# `run "${driver}" ts-up` with neither $status nor $output examined. `run`
# captures the exit code precisely so it cannot fail the test, so a driver that
# emits every log line these tests read and THEN dies satisfies all of them.
#
# scripts/check-vacuous-assertions.sh detects this immediately and names it
# precisely. It was simply never run by `make gcp-tf-validate` — only by
# vm-pipeline.sh and demo-pipeline.sh, both of which need a VM. Re-introducing
# the defect left every test/terraform-*.bats suite green in 238s.
# test/terraform-vacuity-gate.bats closes that, and is what this proves.
# ═══════════════════════════════════════════════════════════════════════════
defect "D6  the vacuous assertions (a run whose status nothing examines)"
D6_FILE="test/terraform-vacuity-gate.bats"
D6_TEST="VACGATE no assertion in this repository is incapable of failing"
D6_CONTROL="VACGATE the scanner still distinguishes a violation from a clean tree"
expect_green "$D6_FILE" "$D6_TEST"
expect_green "$D6_FILE" "$D6_CONTROL"
if apply "$TS_BATS" "strip the five anchored status assertions back out" '
lines = s.split("\n")
kept, skipping, removed = [], False, 0
for l in lines:
    if "vacuity-proof anchor" in l:
        skipping = True; removed += 1; continue
    if skipping:
        if l.strip() == "}": skipping = False
        continue
    kept.append(l)
assert removed == 5, "expected 5 vacuity-proof anchors in this file, removed %d" % removed
out = "\n".join(kept)
'; then
	expect_red "$D6_FILE" "$D6_TEST"
	# The control must stay GREEN. It measures the scanner against its own
	# fixtures and has nothing to do with the tree, so a red here would mean the
	# mutation broke something other than what is being measured.
	expect_green "$D6_FILE" "$D6_CONTROL"
fi
unmutate "$TS_BATS"

# ── Restore and prove it ────────────────────────────────────────────────────
restore_all
trap - EXIT

say ""
say "--- restore proof ---"
restore_ok=1
for f in "$DRIVER" "$INSTALLER" "$MAKEFILE" "$TS_BATS"; do
	got="$(sha "$f")"
	if [ "$got" = "${PRISTINE_SHA[$f]}" ]; then
		say "  OK   ${f}"
		say "       ${got}"
	else
		red "  DIFF ${f}"
		red "       want ${PRISTINE_SHA[$f]}"
		red "       got  ${got}"
		restore_ok=0
		FINDINGS=$((FINDINGS + 1))
	fi
done
[ "$restore_ok" -eq 1 ] && say "  all four files byte-identical to their pre-run state."
rm -f "${SAFE:?}"/*.pristine "$LAST_OUT"

say ""
if [ "$FINDINGS" -eq 0 ]; then
	grn "defect-reintroduction: 6/6 shipped defects re-introduced, each caught by a named test."
	exit 0
fi
red "defect-reintroduction: ${FINDINGS} finding(s). A GREEN above means a shipped defect"
red "can come back without any test noticing. Read the block it appeared under."
exit 1
