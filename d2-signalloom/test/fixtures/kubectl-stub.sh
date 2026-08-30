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
  *" -i "*|*" --stdin "*) cat >>"${KUBECTL_STDIN_LOG:-/dev/null}" ;;
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
  *)
    :
    ;;
esac

exit "${KUBECTL_STUB_RC:-0}"
