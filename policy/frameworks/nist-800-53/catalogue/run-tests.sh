#!/bin/sh
# Run every nist-800-53 pack test. Exit non-zero if any fails.
#
# These tests check claims the Go conformance harness cannot: that a control
# identifier is real (anchor-test.sh, against the published NIST OSCAL
# catalogue) and that a check is either priced or explicitly declared unpriced
# (pricing-test.sh). They are plain POSIX sh + jq + awk so they run anywhere
# the repo is checked out, with no Go toolchain.
#
# Not yet wired into the Makefile or CI -- the Makefile is outside this pack.
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RC=0

for T in anchor-test.sh pricing-test.sh; do
	"$HERE/$T" || RC=1
done

if [ "$RC" -eq 0 ]; then
	echo "nist-800-53: all pack tests PASS"
else
	echo "nist-800-53: pack tests FAILED" >&2
fi
exit "$RC"
