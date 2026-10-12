#!/bin/sh
# Run every finos-aigf pack test. Exit non-zero if any fails.
#
# One test today: that a check is either priced or explicitly declared unpriced
# with a reason code from the allow-list (pricing-test.sh). Plain POSIX sh + jq
# + awk, so it runs anywhere the repo is checked out, with no Go toolchain.
#
# There is no anchor-test.sh here. The sibling packs anchor their control
# identifiers against a machine-readable catalogue (NIST OSCAL, the
# Publications Office Cellar XHTML). The FINOS AI Governance Framework
# publishes its mitigations as Jekyll markdown in a git repository, and the
# pack pins the commit in v1.0/README.md instead.
#
# Not yet wired into the Makefile or CI -- the Makefile is outside this pack.
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RC=0

for T in pricing-test.sh; do
	"$HERE/$T" || RC=1
done

if [ "$RC" -eq 0 ]; then
	echo "finos-aigf: all pack tests PASS"
else
	echo "finos-aigf: pack tests FAILED" >&2
fi
exit "$RC"
