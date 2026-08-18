#!/usr/bin/env bash
# tf-variable-audit.sh — assert every Terraform variable block declares a required attribute.
#
#   tf-variable-audit.sh type|description <dir> [<dir>...]
#
# Exits 0 when every `variable "…" {` block in every .tf file under the given directories
# declares the named attribute at the block's own nesting level. Exits 1 and names each offender
# otherwise. Exits 2 on misuse.
#
# Why a script and not a grep: `type` and `description` also appear inside nested blocks
# (validation, object type expressions, lifecycle_rule.condition), so a file-level grep both
# misses a genuinely undeclared variable and reports false positives on a compliant one. This
# tracks brace depth so it only counts declarations that belong to the variable block itself.
#
# This VERIFIES AND FAILS. It never rewrites a file to make itself pass — a guard that repairs
# what it detects can never go red, so the broken input ships green and the alarm is silent.

set -eo pipefail

usage() {
  echo "usage: $(basename "$0") type|description <dir> [<dir>...]" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage

attribute="$1"
shift

case "$attribute" in
type | description) ;;
*) usage ;;
esac

offenders=()
scanned=0

while IFS= read -r file; do
  [ -n "$file" ] || continue
  scanned=$((scanned + 1))

  # Walk the file tracking brace depth. Depth 1 inside a variable block is the block's own
  # level; anything deeper belongs to a nested block and does not satisfy the requirement.
  awk -v want="$attribute" -v path="$file" '
    function flush() {
      if (in_var && !found) {
        if (empty) printf "%s: variable %s has an empty %s\n", path, name, want
        else printf "%s: variable %s has no %s\n", path, name, want
      }
      in_var = 0; found = 0; empty = 0; name = ""
    }
    {
      line = $0
      sub(/#.*$/, "", line)
      sub(/\/\/.*$/, "", line)
    }
    !in_var && line ~ /^[[:space:]]*variable[[:space:]]+"[^"]+"[[:space:]]*\{/ {
      flush()
      in_var = 1; found = 0; empty = 0; depth = 0
      match(line, /"[^"]+"/)
      name = substr(line, RSTART + 1, RLENGTH - 2)
    }
    in_var {
      opens = gsub(/\{/, "{", line)
      closes = gsub(/\}/, "}", line)
      before = depth
      if (before == 1 && line ~ ("^[[:space:]]*" want "[[:space:]]*=")) {
        # Presence is not enough. `description = ""` declares the attribute and says nothing,
        # which is exactly what ISC-15 forbids; an empty type is meaningless too. Take the
        # right-hand side and require it to contain something other than quotes and spaces.
        rhs = line
        sub(/^[^=]*=[[:space:]]*/, "", rhs)
        gsub(/[[:space:]]/, "", rhs)
        if (rhs != "" && rhs != "\"\"" && rhs != "''") found = 1
        else empty = 1
      }
      depth += opens - closes
      if (depth <= 0 && before > 0) flush()
      next
    }
    END { flush() }
  ' "$file"
done < <(find "$@" -type f -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null | sort) >/tmp/.tf-variable-audit.$$ || true

mapfile -t offenders </tmp/.tf-variable-audit.$$
rm -f /tmp/.tf-variable-audit.$$

if [ "$scanned" -eq 0 ]; then
  echo "tf-variable-audit: no .tf files found under: $*" >&2
  echo "tf-variable-audit: refusing to report success on an empty scan" >&2
  exit 1
fi

if [ "${#offenders[@]}" -gt 0 ]; then
  printf '%s\n' "${offenders[@]}" >&2
  printf 'tf-variable-audit: %d variable(s) missing %s across %d file(s)\n' \
    "${#offenders[@]}" "$attribute" "$scanned" >&2
  exit 1
fi

exit 0
