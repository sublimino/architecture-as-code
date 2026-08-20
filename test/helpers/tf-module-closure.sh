#!/usr/bin/env bash
#
# tf-module-closure.sh -- print every directory a Terraform root can create
# resources in.
#
# `terraform destroy` against a root destroys everything in that root's state,
# and a root's state covers the root's own resources PLUS every resource
# declared by every module it calls, transitively. So "does the environments
# root declare a storage bucket?" is the wrong question -- the right one is
# "can a destroy of the environments root reach a storage bucket?", and only the
# closure answers it.
#
# The distinction is not academic here. `terraform/environments/*.tf` declares
# no `resource` blocks at all: every resource it owns comes from a module. A
# guard that grepped only the root's own files would be green today, would stay
# green if `modules/observability` (which DOES declare the audit bucket) were
# wired into the environments root tomorrow, and would report nothing on the
# morning the audit bucket vanished. Absence-of-bad is trivially satisfied by
# nothing-being-present; this walks to where the resources actually are.
#
# Usage:  tf-module-closure.sh <root-dir>
# Output: one absolute directory per line, sorted, starting with the root.
#
# Only LOCAL module sources are followed -- those beginning './' or '../'. A
# registry or git source is not a directory in this tree, cannot be greppped,
# and is out of scope by construction. If one is ever added, it is reported on
# stderr rather than silently skipped, because "we followed everything" and "we
# followed everything we knew how to" are different claims.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <root-dir>\n' "$(basename "$0")" >&2
  exit 2
fi

root="$1"
[ -d "$root" ] || {
  printf 'tf-module-closure: no such directory: %s\n' "$root" >&2
  exit 2
}
root="$(cd "$root" && pwd)"

# Emit the local module sources declared in one directory's *.tf files.
#
# Comment lines are stripped first. The environments root carries commented-out
# `module "edge"` and `module "ci-runner"` blocks; those are not in the graph
# today, and counting them would make the guard report on configuration that
# does not exist. Uncommenting one puts it back in the closure on the next run,
# which is the behaviour we want.
#
# `source = "hashicorp/google"` inside required_providers is excluded by the
# './' or '../' requirement rather than by trying to parse block context.
local_sources() {
  local dir="$1"
  local -a files=()
  local f
  for f in "$dir"/*.tf; do
    [ -f "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0

  sed 's/[[:space:]]*#.*$//' "${files[@]}" |
    grep -oE 'source[[:space:]]*=[[:space:]]*"[^"]+"' |
    sed -E 's/.*"([^"]+)"$/\1/' |
    while IFS= read -r src; do
      case "$src" in
        ./* | ../*) printf '%s\n' "$src" ;;
        *) : ;;
      esac
    done
}

# Breadth-first over the module graph. `seen` is what makes it terminate: a
# module that calls a sibling which calls it back would otherwise loop forever,
# and Terraform itself permits shapes that look like that across a diamond.
declare -a queue=("$root")
declare -a seen=()

is_seen() {
  local candidate="$1" s
  for s in ${seen[@]+"${seen[@]}"}; do
    [ "$s" = "$candidate" ] && return 0
  done
  return 1
}

while [ "${#queue[@]}" -gt 0 ]; do
  current="${queue[0]}"
  queue=("${queue[@]:1}")

  is_seen "$current" && continue
  seen+=("$current")

  while IFS= read -r src; do
    [ -n "$src" ] || continue
    if [ ! -d "${current}/${src}" ]; then
      printf 'tf-module-closure: %s references a local module that is not a directory: %s\n' \
        "$current" "$src" >&2
      exit 1
    fi
    resolved="$(cd "${current}/${src}" && pwd)"
    is_seen "$resolved" || queue+=("$resolved")
  done < <(local_sources "$current")
done

printf '%s\n' "${seen[@]}" | sort -u
