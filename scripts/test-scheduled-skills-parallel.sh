#!/usr/bin/env bash
# @target scripts/lib/scheduled-skills-runner.py
# Thin public CLI. Process control and evidence validation live in one testable module.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/lib/scheduled-skills-runner.py" "$@"
