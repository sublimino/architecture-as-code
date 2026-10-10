#!/bin/sh
# Run every pack test for the three EU-act packs: cra, dora and nis2.
#
# These tests check claims the Go conformance harness cannot: that a cited
# article or annex actually exists in the act and says what the pack says it
# says (anchor-test.sh, against the publisher's own XHTML), and that every
# check is either priced or explicitly declared unpriced (pricing-test.sh).
# Plain POSIX sh + jq + awk, so they run anywhere the repo is checked out with
# no Go toolchain.
#
# This catalogue covers three packs rather than one because the three acts are
# one family and the tooling is identical. It lives under cra/ because
# policy/frameworks/ is outside this work's ownership; hoisting it to a shared
# location is the right follow-up.
#
# Not wired into the Makefile or CI -- the Makefile is outside these packs.
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RC=0

for T in anchor-test.sh pricing-test.sh; do
	"$HERE/$T" || RC=1
done

if [ "$RC" -eq 0 ]; then
	echo "cra/dora/nis2: all pack tests PASS"
else
	echo "cra/dora/nis2: pack tests FAILED" >&2
fi
exit "$RC"
