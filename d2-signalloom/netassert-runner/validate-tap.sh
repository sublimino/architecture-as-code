#!/bin/sh
# Validate the strict TAP subset emitted by Netassert v2.1.5. Assertion failure
# (`not ok`) is valid evidence; malformed or incomplete TAP is execution error.
set -eu

tap_file=${1:?usage: validate-tap.sh TAP_FILE}
if [ ! -f "$tap_file" ]; then
  echo "validate-tap: TAP file does not exist: ${tap_file}" >&2
  exit 2
fi

awk '
function invalid(message) {
  if (!failed) {
    print "validate-tap: " message > "/dev/stderr"
  }
  failed = 1
}

$0 == "TAP version 14" {
  versions++
  if (versions > 1) invalid("expected exactly one TAP version header")
  next
}

$0 ~ /^Bail out!/ {
  invalid("bailout record present")
  next
}

$0 ~ /^1\.\.[0-9]+$/ {
  plans++
  plan = substr($0, 4) + 0
  if (plans > 1 || plan < 1) invalid("expected exactly one plan with positive count")
  next
}

$0 ~ /^(not )?ok / {
  result = $0
  sub(/^not /, "", result)
  sub(/^ok /, "", result)
  separator = index(result, " - ")
  if (separator == 0) {
    invalid("malformed assertion result")
    next
  }
  number = substr(result, 1, separator - 1)
  if (number !~ /^[0-9]+$/) {
    invalid("malformed assertion result number")
    next
  }
  number += 0
  result_count++
  if (seen[number]) invalid("duplicate result number " number)
  seen[number] = 1
  if (plans == 1 && number > plan) invalid("result number outside plan: " number)
  next
}

$0 == "" || $0 ~ /^[[:space:]]/ || $0 ~ /^#/ { next }

{ invalid("malformed top-level record: " $0) }

END {
  if (versions != 1) invalid("expected exactly one TAP version header")
  if (plans != 1) invalid("expected exactly one plan")
  if (plans == 1 && result_count != plan) {
    invalid("result count " result_count " does not match plan " plan)
  }
  if (plans == 1) {
    for (number in seen) {
      if (number < 1 || number > plan) invalid("result number outside plan: " number)
    }
    for (number = 1; number <= plan; number++) {
      if (!seen[number]) invalid("missing result number " number)
    }
  }
  exit failed ? 2 : 0
}
' "$tap_file"
