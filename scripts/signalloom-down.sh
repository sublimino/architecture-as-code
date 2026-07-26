#!/usr/bin/env bash
# signalloom-down.sh — Remove the Signal Loom frontend namespace.
# Shared Bao infrastructure remains intact; run signalloom-up.sh to restore.

set -eo pipefail

SCRIPT_DIR="$(dirname -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "${SCRIPT_DIR}" && pwd -P)"
exec "${SCRIPT_DIR}/resourceset-down.sh" signalloom-apps /tmp/.signalloom-apps-resourceset-inputs.json fe-signalloom
