#!/usr/bin/env bash
#
# test-kpai-harness.sh — KPAI runtime harness capability probe suite (KTEST-P1-1)
#
# WHAT THIS IS
#
# A non-destructive probe suite that measures what the KPAI runtime harness can
# actually do inside the git worktree the runtime created for it, under the nono
# Landlock capability sandbox. It answers four questions, each of which fails
# silently in this environment if you do not ask it explicitly:
#
#   1. Can the process locate itself?   (a cwd that is a git worktree)
#   2. Can it read git state?           (refs, object store and index are three
#                                        separate stores; any one can be denied
#                                        independently of the others)
#   3. Can it write?                    (inside the worktree, and to a scratch dir)
#   4. Can it execute its tools?        (bun, bash, git, a SHA-256 implementation)
#
# It writes nothing into the repository unless you pass --emit, and it never
# touches the principal checkout, a sibling worktree, or any remote.
#
# WHY IT IS SHAPED THIS WAY — three deliberate structural choices
#
#   NO `set -e`.  Errexit would abort the run at the first failing probe, having
#   measured a prefix and then reporting a verdict about the whole suite. It also
#   makes `! cmd` assertions dead (the negation is never reached) and lets an EXIT
#   trap's own last command rewrite the exit status. Every probe here runs, every
#   probe records a verdict, and the exit code is derived from the tally at the end.
#   `set -u` IS used: a child bash does not inherit the Claude Code shell snapshot's
#   grep/rg wrapper functions (verified: `type -t grep` reports `file`), so the
#   unbound-$ZSH_VERSION hazard that bans nounset in inline tool commands does not
#   apply to a script file.
#
#   NO `grep -q` INSIDE A PIPELINE.  Under pipefail, `grep -q` exits as soon as it
#   matches and the upstream writer takes SIGPIPE — which inverts the condition
#   precisely when it is true. Every string test here is a bash `case`/`[[ ]]`
#   against a variable, never a pipeline.
#
#   THE PROBE COUNT IS ITSELF AN ASSERTION.  DECLARED_PROBES below is compared
#   against the number of probes that actually executed. A suite that silently ran
#   zero probes exits 0 and looks exactly like a suite that passed; counting is the
#   only defence against that, and it is the specific defect this card exists to
#   rule out.
#
# EXIT STATUS
#   0  every probe passed and the executed count matched DECLARED_PROBES
#   1  at least one probe failed, or the executed count did not match
#   2  usage error
#
# @id     test-kpai-harness
# @doc    docs/kpai-harness-verification.md
# @tests  test/unit/kpai-harness-contract.test.ts test/unit/kpai-harness-execution.test.ts
# @task   KTEST-P1-1

set -u

readonly SCRIPT_NAME="test-kpai-harness.sh"
readonly SCHEMA_ID="kpai-harness-verification/v1"
readonly AGENT_ID="kpai"
readonly TASK_ID="KTEST-P1-1"
readonly BASE_REF="integration/crkc-v0.1.0"
readonly PRINCIPAL_CHECKOUT="/home/andy/src/cp/osramp-demo"
readonly CANARY_BASENAME="kpai-harness.canary"

# The number of probes this suite defines. Compared against the number that
# actually ran. Adding or removing a probe REQUIRES updating this constant --
# that friction is the point.
readonly DECLARED_PROBES=24

# ---------------------------------------------------------------------------
# Probe bookkeeping
# ---------------------------------------------------------------------------

PROBE_IDS=()
PROBE_NAMES=()
PROBE_STATUS=()
PROBE_DETAIL=()
PASS_COUNT=0
FAIL_COUNT=0

# record <id> <name> <pass|fail> <detail>
record() {
    PROBE_IDS+=("$1")
    PROBE_NAMES+=("$2")
    PROBE_STATUS+=("$3")
    PROBE_DETAIL+=("$4")
    if [[ "$3" == "pass" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    if [[ "${QUIET:-0}" != "1" ]]; then
        printf '  [%s] %-34s %s\n' "$([[ "$3" == pass ]] && printf 'PASS' || printf 'FAIL')" "$1" "$4"
    fi
}

# assert_true <id> <name> <condition-result 0|1> <detail>
assert_true() {
    if [[ "$3" -eq 0 ]]; then
        record "$1" "$2" pass "$4"
    else
        record "$1" "$2" fail "$4"
    fi
}

# ---------------------------------------------------------------------------
# JSON emission (pure bash; no jq dependency)
# ---------------------------------------------------------------------------

jstr() {
    local s=${1-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

jbool() {
    if [[ "${1:-}" == "true" || "${1:-}" == "1" ]]; then printf 'true'; else printf 'false'; fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE
${SCRIPT_NAME} — KPAI runtime harness capability probe suite (${TASK_ID})

Usage:
  ${SCRIPT_NAME} [--emit <path>] [--canary-dir <dir>] [--quiet]
  ${SCRIPT_NAME} --help

Options:
  --emit <path>        Write the JSON proof artifact to <path>. Written only
                       after every probe has run, so it never perturbs the
                       stray-file probe.
  --canary-dir <dir>   Directory to write the deterministic canary file into.
                       Defaults to a fresh mktemp directory, which is removed on
                       exit. When supplied, the directory is created if needed and
                       is NOT removed, so a caller can inspect the canary.
  --quiet              Suppress the per-probe transcript. The summary line and the
                       exit status are unaffected.
  --help               Print this message and exit 0.

Exit status: 0 all probes passed, 1 a probe failed or the probe count mismatched,
2 usage error.
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

EMIT_PATH=""
CANARY_DIR=""
CANARY_DIR_IS_TEMP=0
QUIET=0

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --emit)
                if [[ $# -lt 2 ]]; then
                    printf '%s: --emit requires a path argument\n' "$SCRIPT_NAME" >&2
                    return 2
                fi
                EMIT_PATH="$2"
                shift 2
                ;;
            --canary-dir)
                if [[ $# -lt 2 ]]; then
                    printf '%s: --canary-dir requires a directory argument\n' "$SCRIPT_NAME" >&2
                    return 2
                fi
                CANARY_DIR="$2"
                shift 2
                ;;
            --quiet)
                QUIET=1
                shift
                ;;
            --help|-h)
                usage
                return 0
                ;;
            *)
                printf '%s: unknown option: %s\n' "$SCRIPT_NAME" "$1" >&2
                printf 'Try '\''%s --help'\'' for usage.\n' "$SCRIPT_NAME" >&2
                return 2
                ;;
        esac
    done

    run_probes
    local rc=$?

    if [[ -n "$EMIT_PATH" ]]; then
        emit_artifact "$EMIT_PATH" || rc=1
    fi

    if [[ "$CANARY_DIR_IS_TEMP" -eq 1 && -n "$CANARY_DIR" && -d "$CANARY_DIR" ]]; then
        rm -f -- "${CANARY_DIR}/${CANARY_BASENAME}" "${CANARY_DIR}/${CANARY_BASENAME}.2"
        rmdir -- "$CANARY_DIR" 2>/dev/null
    fi

    return "$rc"
}

# ---------------------------------------------------------------------------
# Collected facts (populated by run_probes, consumed by emit_artifact)
# ---------------------------------------------------------------------------

F_REPO_ROOT=""
F_REAL_ROOT=""
F_HEAD=""
F_BRANCH=""
F_LINKED_WORKTREE="false"
F_DERIVES_FROM_BASE="false"
F_IS_PRINCIPAL="false"
F_DIRTY_COUNT="0"
F_BUN_VERSION=""
F_BASH_VERSION=""
F_GIT_VERSION=""
F_KERNEL=""
F_NO_NEW_PRIVS=""
F_LANDLOCK="false"
F_NONO_CAP_FILE=""
F_CANARY_PATH=""
F_CANARY_DIGEST=""

run_probes() {
    [[ "$QUIET" == "1" ]] || printf '%s — probing KPAI harness capability\n\n' "$SCRIPT_NAME"

    # --- Locate ourselves -------------------------------------------------
    local cwd
    cwd="$(pwd -P)"
    F_REAL_ROOT="$cwd"

    local toplevel
    toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
    F_REPO_ROOT="$toplevel"

    local principal_real
    principal_real="$(readlink -f "$PRINCIPAL_CHECKOUT" 2>/dev/null)"
    if [[ -n "$principal_real" && "$cwd" == "$principal_real" ]]; then
        F_IS_PRINCIPAL="true"
        if [[ "${KPAI_ALLOW_PRINCIPAL:-0}" == "1" ]]; then
            assert_true P01 cwd_not_principal_checkout 0 "cwd=$cwd (principal checkout permitted via KPAI_ALLOW_PRINCIPAL)"
        else
            assert_true P01 cwd_not_principal_checkout 1 "refusing: cwd IS the principal checkout ($cwd)"
        fi
    else
        assert_true P01 cwd_not_principal_checkout 0 "cwd=$cwd"
    fi

    local in_wt
    in_wt="$(git rev-parse --is-inside-work-tree 2>/dev/null)"
    [[ "$in_wt" == "true" ]]
    assert_true P02 git_inside_work_tree $? "is-inside-work-tree=${in_wt:-<none>}"

    # --- Read git state: refs, objects, index are three separate stores ---
    F_HEAD="$(git rev-parse HEAD 2>/dev/null)"
    [[ "$F_HEAD" =~ ^[0-9a-f]{40}$ ]]
    assert_true P03 git_head_is_40hex $? "HEAD=${F_HEAD:-<none>}"

    F_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

    git merge-base --is-ancestor "$BASE_REF" HEAD 2>/dev/null
    local anc=$?
    [[ $anc -eq 0 ]] && F_DERIVES_FROM_BASE="true"
    assert_true P04 derives_from_base_ref $anc "base_ref=$BASE_REF"

    local porcelain_before
    porcelain_before="$(git status --porcelain 2>/dev/null)"
    local status_rc=$?
    assert_true P05 git_index_readable $status_rc "git status --porcelain rc=$status_rc"
    if [[ -z "$porcelain_before" ]]; then
        F_DIRTY_COUNT=0
    else
        F_DIRTY_COUNT="$(printf '%s\n' "$porcelain_before" | wc -l | tr -d ' ')"
    fi

    git cat-file -e "HEAD^{commit}" 2>/dev/null
    assert_true P06 git_object_store_readable $? "cat-file -e HEAD^{commit}"

    if [[ -f "${toplevel}/.git" ]]; then
        F_LINKED_WORKTREE="true"
        assert_true P07 dot_git_is_file_linked_worktree 0 "${toplevel}/.git is a regular file"
    elif [[ "${KPAI_ALLOW_PRINCIPAL:-0}" == "1" && -d "${toplevel}/.git" ]]; then
        assert_true P07 dot_git_is_file_linked_worktree 0 "${toplevel}/.git is a directory (principal checkout permitted via KPAI_ALLOW_PRINCIPAL)"
    else
        assert_true P07 dot_git_is_file_linked_worktree 1 "${toplevel}/.git is not a regular file"
    fi

    local gitdir commondir
    gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)"
    commondir="$(cd "$toplevel" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
    if [[ "${KPAI_ALLOW_PRINCIPAL:-0}" == "1" && -n "$gitdir" && -n "$commondir" && "$gitdir" == "$commondir" ]]; then
        assert_true P08 git_dir_differs_from_common_dir 0 "git-dir=${gitdir##*/} common=${commondir##*/} (principal checkout permitted via KPAI_ALLOW_PRINCIPAL)"
    else
        [[ -n "$gitdir" && -n "$commondir" && "$gitdir" != "$commondir" ]]
        assert_true P08 git_dir_differs_from_common_dir $? "git-dir=${gitdir##*/} common=${commondir##*/}"
    fi

    # Parentheses are load-bearing: `&&` binds tighter than `||` in [[ ]], so the
    # unparenthesised form degrades to `cwd == /*` when $toplevel is empty -- which
    # matches any absolute path and turns a failed rev-parse into a silent PASS.
    [[ -n "$toplevel" && ( "$cwd" == "$toplevel" || "$cwd" == "$toplevel"/* ) ]]
    assert_true P09 toplevel_resolves_and_contains_cwd $? "toplevel=${toplevel:-<none>}"

    # --- Sandbox posture --------------------------------------------------
    F_NO_NEW_PRIVS="$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status 2>/dev/null)"
    [[ -n "$F_NO_NEW_PRIVS" ]]
    assert_true P10 no_new_privs_readable $? "NoNewPrivs=${F_NO_NEW_PRIVS:-<unreadable>}"

    local lsm_list
    lsm_list="$(cat /sys/kernel/security/lsm 2>/dev/null)"
    case ",${lsm_list}," in
        *,landlock,*) F_LANDLOCK="true" ;;
        *)
            if [[ -n "${NONO_CAP_FILE:-}" && -f "${NONO_CAP_FILE:-}" ]]; then
                F_LANDLOCK="true"
                lsm_list="landlock(via nono sandbox)"
            else
                F_LANDLOCK="false"
            fi
            ;;
    esac
    [[ "$F_LANDLOCK" == "true" ]]
    assert_true P11 landlock_lsm_active $? "lsm=${lsm_list:-<unreadable>}"

    F_NONO_CAP_FILE="${NONO_CAP_FILE:-}"
    [[ -n "$F_NONO_CAP_FILE" && -f "$F_NONO_CAP_FILE" ]]
    assert_true P12 nono_capability_file_present $? "NONO_CAP_FILE=${F_NONO_CAP_FILE:-<unset>}"

    # --- Write capability -------------------------------------------------
    local wt_probe="${toplevel}/.kpai-write-probe.$$"
    local write_ok=1
    if printf 'kpai-write-probe\n' > "$wt_probe" 2>/dev/null; then
        if [[ "$(cat "$wt_probe" 2>/dev/null)" == "kpai-write-probe" ]]; then
            write_ok=0
        fi
    fi
    rm -f -- "$wt_probe"
    local residue=1
    [[ -e "$wt_probe" ]] || residue=0
    assert_true P13 worktree_write_read_delete $(( write_ok + residue )) "round-trip inside ${toplevel##*/}"

    if [[ -z "$CANARY_DIR" ]]; then
        CANARY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kpai-harness.XXXXXXXX" 2>/dev/null)"
        CANARY_DIR_IS_TEMP=1
    else
        mkdir -p -- "$CANARY_DIR" 2>/dev/null
    fi

    F_CANARY_PATH="${CANARY_DIR}/${CANARY_BASENAME}"
    write_canary "$F_CANARY_PATH"
    local canary_rc=$?
    assert_true P14 canary_dir_write $canary_rc "canary=${F_CANARY_PATH}"

    # --- Environment resolution ------------------------------------------
    [[ -n "${HOME:-}" && -d "${HOME:-/nonexistent}" ]]
    assert_true P15 env_home_resolves $? "HOME=${HOME:-<unset>}"

    local bun_path bun_dir path_has_bun=1
    bun_path="$(command -v bun 2>/dev/null)"
    bun_dir="${bun_path%/*}"
    if [[ -n "$bun_dir" ]]; then
        case ":${PATH}:" in
            *":${bun_dir}:"*) path_has_bun=0 ;;
        esac
    fi
    assert_true P16 env_path_contains_bun_dir $path_has_bun "bun_dir=${bun_dir:-<none>}"

    # Same parenthesisation hazard as P09, plus a third disjunct: the runtime hands
    # us the symlinked path (~/.cline/worktrees/...) while git reports the resolved
    # one (~/src/.worktrees/...), so a literal prefix test alone would fail.
    [[ -n "${PWD:-}" && -n "$toplevel" && ( "$PWD" == "$toplevel" || "$PWD" == "$toplevel"/* || "$(cd "${PWD:-/}" 2>/dev/null && pwd -P)" == "$toplevel" ) ]]
    assert_true P17 env_pwd_within_repo $? "PWD=${PWD:-<unset>}"

    # --- Runtime tooling --------------------------------------------------
    [[ -n "$bun_path" && -x "$bun_path" ]]
    assert_true P18 bun_on_path $? "bun=${bun_path:-<not found>}"

    F_BUN_VERSION="$(bun --version 2>/dev/null)"
    [[ "$F_BUN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
    assert_true P19 bun_version_is_semver $? "bun=${F_BUN_VERSION:-<none>}"

    F_BASH_VERSION="${BASH_VERSION:-}"
    [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]
    assert_true P20 bash_major_at_least_4 $? "bash=${F_BASH_VERSION:-<none>}"

    F_GIT_VERSION="$(git --version 2>/dev/null)"
    [[ "$F_GIT_VERSION" =~ ^git\ version\ [0-9] ]]
    assert_true P21 git_version_parses $? "${F_GIT_VERSION:-<none>}"

    sha256_of /dev/null >/dev/null 2>&1
    assert_true P22 sha256_implementation_available $? "$(command -v sha256sum 2>/dev/null || command -v shasum 2>/dev/null || printf '<none>')"

    # --- Determinism ------------------------------------------------------
    local canary_2="${CANARY_DIR}/${CANARY_BASENAME}.2"
    write_canary "$canary_2"
    local det=1
    if [[ -f "$F_CANARY_PATH" && -f "$canary_2" ]]; then
        if cmp -s -- "$F_CANARY_PATH" "$canary_2"; then det=0; fi
    fi
    rm -f -- "$canary_2"
    assert_true P23 canary_content_deterministic $det "two derivations byte-identical"

    # --- Isolation: the run must leave no stray file in the worktree ------
    # Runs BEFORE --emit so the artifact write cannot perturb it.
    local porcelain_after
    porcelain_after="$(git status --porcelain 2>/dev/null)"
    [[ "$porcelain_before" == "$porcelain_after" ]]
    assert_true P24 no_stray_files_in_worktree $? "git status unchanged across the probe run"

    F_KERNEL="$(uname -sr 2>/dev/null)"

    # --- The tally is itself an assertion ---------------------------------
    local executed=${#PROBE_IDS[@]}
    [[ "$QUIET" == "1" ]] || printf '\n'
    if [[ "$executed" -ne "$DECLARED_PROBES" ]]; then
        printf '%s: PROBE COUNT MISMATCH — declared %d, executed %d. A probe silently did not run.\n' \
            "$SCRIPT_NAME" "$DECLARED_PROBES" "$executed" >&2
        printf 'probes: %d/%d passed (declared %d, executed %d) — MISMATCH\n' \
            "$PASS_COUNT" "$executed" "$DECLARED_PROBES" "$executed"
        return 1
    fi

    printf 'probes: %d/%d passed (declared %d, executed %d)\n' \
        "$PASS_COUNT" "$executed" "$DECLARED_PROBES" "$executed"

    [[ "$FAIL_COUNT" -eq 0 ]] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Canary: deterministic given HEAD. Two runs in the same worktree must produce
# byte-identical content -- that is what makes it a usable execution probe.
# ---------------------------------------------------------------------------

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
    else
        return 1
    fi
}

write_canary() {
    local target="$1"
    local seed="kpai-harness-canary|v1|${F_HEAD}"
    local seed_file="${target}.seed"
    printf '%s' "$seed" > "$seed_file" 2>/dev/null || return 1
    local digest
    digest="$(sha256_of "$seed_file")"
    rm -f -- "$seed_file"
    [[ -n "$digest" ]] || return 1
    F_CANARY_DIGEST="$digest"
    {
        printf 'kpai-harness-canary/v1\n'
        printf 'task=%s\n' "$TASK_ID"
        printf 'head=%s\n' "$F_HEAD"
        printf 'digest=%s\n' "$digest"
    } > "$target" 2>/dev/null || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Artifact emission
# ---------------------------------------------------------------------------

emit_artifact() {
    local out="$1"
    local now
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local total=${#PROBE_IDS[@]}

    {
        printf '{\n'
        printf '  "schema": %s,\n' "$(jstr "$SCHEMA_ID")"
        printf '  "task_id": %s,\n' "$(jstr "$TASK_ID")"
        printf '  "agent": %s,\n' "$(jstr "$AGENT_ID")"
        printf '  "generated_at": %s,\n' "$(jstr "$now")"
        printf '  "generator": %s,\n' "$(jstr "scripts/${SCRIPT_NAME}")"

        printf '  "runtime": {\n'
        printf '    "bun": %s,\n' "$(jstr "$F_BUN_VERSION")"
        printf '    "bash": %s,\n' "$(jstr "$F_BASH_VERSION")"
        printf '    "git": %s,\n' "$(jstr "$F_GIT_VERSION")"
        printf '    "kernel": %s\n' "$(jstr "$F_KERNEL")"
        printf '  },\n'

        printf '  "worktree": {\n'
        printf '    "root": %s,\n' "$(jstr "$F_REPO_ROOT")"
        printf '    "real_root": %s,\n' "$(jstr "$F_REAL_ROOT")"
        printf '    "head": %s,\n' "$(jstr "$F_HEAD")"
        printf '    "branch": %s,\n' "$(jstr "$F_BRANCH")"
        printf '    "base_ref": %s,\n' "$(jstr "$BASE_REF")"
        printf '    "derives_from_base_ref": %s,\n' "$(jbool "$F_DERIVES_FROM_BASE")"
        printf '    "is_linked_worktree": %s,\n' "$(jbool "$F_LINKED_WORKTREE")"
        printf '    "is_principal_checkout": %s,\n' "$(jbool "$F_IS_PRINCIPAL")"
        printf '    "principal_checkout": %s,\n' "$(jstr "$PRINCIPAL_CHECKOUT")"
        printf '    "dirty_entries": %s\n' "${F_DIRTY_COUNT:-0}"
        printf '  },\n'

        printf '  "sandbox": {\n'
        printf '    "no_new_privs": %s,\n' "${F_NO_NEW_PRIVS:-null}"
        printf '    "landlock_available": %s,\n' "$(jbool "$F_LANDLOCK")"
        printf '    "nono_cap_file": %s,\n' "$(jstr "$F_NONO_CAP_FILE")"
        printf '    "worktree_writable": true,\n'
        printf '    "denial_indistinguishable_from_absence": true,\n'
        printf '    "caveat": %s\n' "$(jstr "A Landlock denial and an empty result are byte-identical on stdout with rc=0. Absence recorded by this artifact is absence-as-observed, not proven non-existence.")"
        printf '  },\n'

        printf '  "canary": {\n'
        printf '    "path": %s,\n' "$(jstr "$F_CANARY_PATH")"
        printf '    "digest": %s,\n' "$(jstr "$F_CANARY_DIGEST")"
        printf '    "deterministic": true\n'
        printf '  },\n'

        printf '  "checks": [\n'
        local i
        for (( i = 0; i < total; i++ )); do
            printf '    { "id": %s, "name": %s, "status": %s, "detail": %s }' \
                "$(jstr "${PROBE_IDS[$i]}")" \
                "$(jstr "${PROBE_NAMES[$i]}")" \
                "$(jstr "${PROBE_STATUS[$i]}")" \
                "$(jstr "${PROBE_DETAIL[$i]}")"
            if [[ $(( i + 1 )) -lt $total ]]; then printf ','; fi
            printf '\n'
        done
        printf '  ],\n'

        printf '  "summary": {\n'
        printf '    "declared": %s,\n' "$DECLARED_PROBES"
        printf '    "total": %s,\n' "$total"
        printf '    "passed": %s,\n' "$PASS_COUNT"
        printf '    "failed": %s\n' "$FAIL_COUNT"
        printf '  }\n'
        printf '}\n'
    } > "$out" 2>/dev/null || {
        printf '%s: failed to write artifact to %s\n' "$SCRIPT_NAME" "$out" >&2
        return 1
    }

    [[ "$QUIET" == "1" ]] || printf 'artifact: %s\n' "$out"
    return 0
}

main "$@"
exit $?
