#!/usr/bin/env bash
# d2-signalloom/test/fixtures/kubectl-stub.sh — recording kubectl double
#
# A witness, not a simulator. It records argv and stdin so the credential tests
# can assert what WOULD have been executed — which is how "the key never reaches
# argv" is checked — and answers the handful of reads the scripts make.
#
# A real file rather than a heredoc inside the .bats: the JSON and jsonpath
# responses need quotes and backslashes that do not survive being written
# through a quoted heredoc from a generator script. That mangling produced a
# stub which silently returned empty for every query, and empty is exactly what
# "absent" looks like — the tests failed for a reason that had nothing to do
# with the code under test.
#
# Behaviour is driven entirely by environment variables, so one file serves
# every scenario:
#   KUBECTL_ARGV_LOG          append argv here
#   KUBECTL_STDIN_LOG         append stdin here (when -i/--stdin is present)
#   KUBECTL_STUB_BAO_VALUE    what `bao kv get -field=value` returns
#   KUBECTL_STUB_SECRET_JSON  a Secret object for `get secret ... -o json`
#   KUBECTL_STUB_RC           exit code (default 0)

printf '%s\n' "$*" >>"${KUBECTL_ARGV_LOG:-/dev/null}"

case " $* " in
  # The credential arrives here on stdin; recording it is how the "never in
  # argv" assertion is shown to be non-vacuous.
  *" -i "*|*" --stdin "*)
    cat >>"${KUBECTL_STDIN_LOG:-/dev/null}"
    ;;
  # `-f -` reads a manifest on stdin. A stub that does not drain it makes the
  # PRODUCER die of SIGPIPE, and under `set -o pipefail` the whole pipeline
  # returns 141 — which surfaces as the script "failing" for no visible reason.
  #
  # This was latent until the stub started emitting a real manifest: while it
  # returned nothing, there was nothing to write, so no SIGPIPE. In other words
  # the earlier tests were passing an EMPTY pipeline and asserting only on argv.
  # Fixing one silent-stub defect exposed the next one down.
  #
  # Drained ONLY when stdin is genuinely a pipe. An unconditional `cat` blocks
  # forever on a terminal or on any inherited descriptor that is never closed,
  # which is how this stub hung a whole bats file — the fix for one silent
  # failure introducing a loud one. `-p` is the precise test: in the real
  # pipeline stdin is a pipe, and a direct call from a test is not.
  *" -f - "*)
    if [ -p /dev/stdin ]; then cat >/dev/null 2>&1 || true; fi
    ;;
esac

args=" $* "

case "$args" in
  *"get pod"*)
    echo "pod/openbao-stub-000"
    ;;
  *"-field=value"*)
    printf '%s' "${KUBECTL_STUB_BAO_VALUE:-}"
    ;;
  # jsonpath BEFORE json, and the json pattern requires a trailing space.
  # "-o jsonpath={...}" contains "-o json" as a prefix, so the looser pattern
  # swallowed every jsonpath query and returned the whole Secret object where a
  # single base64 value was expected. It decoded to nothing, which read as
  # "key present but empty" — a plausible-looking wrong answer rather than an
  # error.
  *"get secret"*"jsonpath={.data."*)
    # Which key was requested, so a multi-key Secret can be simulated.
    want=$(printf '%s' "$args" | sed -n 's/.*jsonpath={\.data\.\([A-Za-z0-9_-]*\)}.*/\1/p')
    if [ -n "$want" ] && [ -n "${KUBECTL_STUB_SECRET_JSON:-}" ]; then
      printf '%s' "$KUBECTL_STUB_SECRET_JSON" \
        | jq -r --arg k "$want" '.data[$k] // empty' 2>/dev/null
    fi
    ;;
  *"get secret"*"-o json "*)
    printf '%s' "${KUBECTL_STUB_SECRET_JSON:-}"
    ;;
  # `create ... --dry-run=client -o yaml` renders a manifest that is piped into
  # `replace --force -f -`. The stub used to return nothing here, so the
  # downstream command received an EMPTY manifest and the tests still passed —
  # they asserted on argv, never on the pipeline carrying anything. Found by the
  # unhandled-query guard below, in this file, which is the point of it.
  *"--dry-run=client"*"-o yaml"*)
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: kagent-anthropic-key\ntype: Opaque\n'
    ;;
  *)
    # An unmatched invocation whose STDOUT is consumed is a stub defect, and it
    # must say so rather than return nothing.
    #
    # Returning empty is what made the two earlier bugs in this file so hard to
    # see: empty is a legal answer — "the key is absent", "the list is empty" —
    # so the stub's silence is indistinguishable from a real state the caller is
    # entitled to observe. A loud failure cannot be mistaken for data.
    #
    # Commands whose EXIT CODE is what matters (create, apply, delete, exec,
    # rollout) are a different case: returning 0 silently is the correct
    # simulation, and failing them would break every test for no benefit. The
    # split is by whether the caller reads stdout, not by whether the stub
    # recognised the verb.
    case "$args" in
      *" -o "*|*"-field="*|*"--output"*)
        printf 'kubectl-stub: unhandled output-producing query: %s\n' "$*" >&2
        exit 64
        ;;
      *)
        :
        ;;
    esac
    ;;
esac

exit "${KUBECTL_STUB_RC:-0}"
