#!/usr/bin/env bash
# SLDC-P5-PRE: name used by the card's Required Tests. Delegates to the
# preflight oracle; all flags and P5_* overrides pass through unchanged.
exec "$(dirname "$0")/p5-operational-preflight.sh" "$@"
