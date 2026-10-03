#!/usr/bin/env bats
#
# @target  test/afm-importer-key.bats
#
# scripts/afm-importer-key.sh reads a key from stdin whenever stdin is not a
# terminal. The suite's no-key cases inherited bats' stdin, so under a
# background or CI runner (stdin an open pipe nobody writes or closes) they
# blocked in `cat` forever: a make test-sldc-offline run sat 30 minutes on
# "fresh run" (2026-10-03). Every case that means "no key" must say so with
# </dev/null.

@test "afm-importer-key.bats completes with stdin an open, silent pipe" {
  local repo_root; repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # The held-open pipe is exactly what a backgrounded runner hands down. A
  # process substitution, not `sleep | bats`: a pipeline would wait for the
  # sleep however fast bats finished.
  # The writer holds no fd bats waits on (stderr, and bats' fd 3) and is
  # killed as soon as bats returns, so nothing waits out its 150 s.
  run timeout 120 bash -c "bats '${repo_root}/test/afm-importer-key.bats' < <(exec sleep 150 2>/dev/null 3>&-); rc=\$?; kill \$! 2>/dev/null; exit \$rc"
  [ "$status" -ne 124 ] || { echo "afm-importer-key.bats blocked on stdin"; return 1; }
  [ "$status" -eq 0 ]
}
