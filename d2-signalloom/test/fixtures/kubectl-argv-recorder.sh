#!/usr/bin/env bash
# d2-signalloom/test/fixtures/kubectl-argv-recorder.sh — kubectl double for the
# argv-exposure tests.
#
# Placed first on PATH under the name `kubectl`, so scripts that call kubectl
# directly (rather than through a $KUBECTL indirection) can be tested without
# changing them. That matters here: the point of these tests is to guard the
# EXISTING olly scripts, and adding an injection seam to them purely to make
# them testable would be the refactor this change is meant not to be.
#
# Records the full command line, drains stdin so a `create ... | apply -f -`
# pipeline does not take SIGPIPE, and succeeds at everything so the scripts run
# to completion.
#
#   KUBECTL_ARGV_LOG   file to append each invocation's argv to

printf '%s\n' "$*" >>"${KUBECTL_ARGV_LOG:-/dev/null}"

# `apply -f -` and friends read a manifest on stdin. Draining unconditionally
# (when stdin is not a terminal) keeps the producer side of the pipe happy.
if [ ! -t 0 ]; then
  cat >/dev/null 2>&1 || true
fi

case " $* " in
  # A minimal manifest, so a downstream `apply -f -` has something to consume.
  *"--dry-run=client"*) printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: stub\n' ;;
  *) : ;;
esac

exit 0
