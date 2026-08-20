#!/usr/bin/env bash
# Shared extractors for the two contracts that broke `make gcp-tf-demo-up
# ENV=demo-2`: the demo-up.sh <-> demo-pipeline.sh environment contract, and the
# toolchain version pins duplicated across three installers.
#
# IN test/helpers/, NOT test/lib/. A bare `lib` entry in ~/.gitignore_global
# matches ANY directory called lib at any depth, so a helper written to
# test/lib/ works locally and is silently never committed. That has already cost
# this repo a shared helper once.
#
# EVERY FUNCTION HERE DERIVES ITS ANSWER FROM THE REAL FILE. None of them carry
# a copy of today's variable names or version numbers. That is the whole point:
# a test that pins the current ten names by hand rots exactly the way the
# contract it is checking rotted — it agrees with itself while the two halves
# drift apart. The bug being guarded against was two files that each tested
# their own half against their own fixtures.

# Names demo-up.sh EXPORTS into the pipeline's environment.
#
# Scoped to the single `printf -v envs '...'` format string, not to the file.
# A whole-file grep for DEMO_[A-Z_]*= would also match the prose above it that
# EXPLAINS the contract, and a guard satisfied by the comment describing it is
# not a guard. Matching only the format-string line is what makes deleting the
# export fail this test rather than silently pass on the paragraph that
# documents the export.
#
# THE LEADING-BOUNDARY CLASS IS LOAD-BEARING. A bare `grep -o 'DEMO_[A-Z_]*=%q'`
# also matches the TAIL of `SL_DEMO_ENV=%q`, because DEMO_ENV is a substring of
# SL_DEMO_ENV. That is not hypothetical: the mutation harness reverted the
# prefix to SL_DEMO_ — the original defect, verbatim — and this extractor
# cheerfully reported the ten correct DEMO_ names, so the contract test passed
# against the exact bug it exists to catch. Found by
# test/mutation-proof-toolchain.sh, which is the argument for mutating the real
# file rather than a fixture.
#
# In the format string every name is preceded by the opening quote or a space,
# so requiring one of those anchors the match to a whole name.
contract_sent_names() {
  local up="$1"
  sed -n "/printf -v envs '/,/^\$/p" "$up" \
    | grep -oE "['[:space:]]DEMO_[A-Z_]+=%q" \
    | sed -E "s/^['[:space:]]//; s/=%q\$//" \
    | sort -u
}

# Names demo-pipeline.sh READS, i.e. appears as ${NAME:-default} or ${NAME:-}.
#
# Parameter expansion with a default is how every injectable boundary in that
# file is declared, so this is the file's own definition of "a thing I can be
# configured with" rather than a list maintained here.
contract_read_names() {
  local pipe="$1"
  grep -oE '\$\{DEMO_[A-Z_]+:-' "$pipe" \
    | sed 's/^\${//; s/:-$//' \
    | sort -u
}

# The REMOTE_* variables demo-up.sh exports into the pipeline's environment,
# paired with the shell variable whose value is sent.
#
# Emits "DEMO_NAME REMOTE_VAR" lines, derived from the `printf -v envs` format
# string and its argument list together — so a path added to the contract is
# discovered here rather than restated. This is what lets a test ask "is every
# remote path the pipeline is told to write to actually provisioned?" without
# any test knowing that today's answer is /opt/signalloom.
contract_remote_path_vars() {
  local up="$1"
  # The exported names, in order, from the format string.
  local -a names
  mapfile -t names < <(contract_sent_names_ordered "$up")
  # The arguments, in order, from the continuation lines that follow it.
  local -a args
  mapfile -t args < <(
    sed -n "/printf -v envs '/,/^\$/p" "$up" \
      | sed -n '2,$p' \
      | grep -oE '"\$[A-Za-z_][A-Za-z0-9_]*"|"\$\{[A-Za-z_][A-Za-z0-9_]*\}[^"]*"' \
      | sed -E 's/^"\$\{?//; s/\}?"$//; s/\}.*$//'
  )
  local i
  for i in "${!names[@]}"; do
    [ -n "${args[$i]:-}" ] || continue
    printf '%s %s\n' "${names[$i]}" "${args[$i]}"
  done
}

# Same extraction as contract_sent_names but ORDER-PRESERVING, because pairing
# names to arguments depends on position.
contract_sent_names_ordered() {
  local up="$1"
  sed -n "/printf -v envs '/,/^\$/p" "$up" \
    | grep -oE "['[:space:]]DEMO_[A-Z_]+=%q" \
    | sed -E "s/^['[:space:]]//; s/=%q\$//"
}

# Version pins, normalised. Emits "TOOL VERSION" lines with any leading `v`
# stripped from the version.
#
# The `v` normalisation is load-bearing rather than cosmetic. install-ci-tools.sh
# stores kind as "0.29.0" and prefixes it at the URL; demo-vm.sh and setup.sh
# store "v0.29.0". A comparison that did not normalise would report those as
# different and be dismissed as a false positive, which is how a divergence test
# gets deleted. A comparison that normalised the tool NAME instead would be
# worse: it would report them as equal when they differ.
#
# Anchored to the start of the line (allowing `readonly`), so a version string
# quoted inside a comment cannot satisfy it. install-ci-tools.sh line 194
# contains the literal "VEXCTL_VERSION=v0.3.0" inside a comment; without the
# anchor that comment alone would satisfy an assertion about vexctl's pin.
toolchain_pins() {
  local file="$1"
  grep -oE '^[[:space:]]*(readonly[[:space:]]+)?[A-Z][A-Z0-9_]*_VERSION="[^"]*"' "$file" \
    | sed -E 's/^[[:space:]]*(readonly[[:space:]]+)?//; s/_VERSION="/ /; s/"$//' \
    | sed -E 's/ v/ /' \
    | sort -u
}

# The pinned version of one tool in one file, normalised. Empty when absent.
toolchain_pin_for() {
  local file="$1" tool="$2"
  toolchain_pins "$file" | awk -v t="$tool" '$1 == t { print $2 }'
}

# Tools pinned in BOTH files, so a pin that only one file carries is not
# reported as a disagreement.
toolchain_common_tools() {
  local a="$1" b="$2"
  comm -12 \
    <(toolchain_pins "$a" | awk '{print $1}') \
    <(toolchain_pins "$b" | awk '{print $1}')
}
