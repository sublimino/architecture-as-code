#!/usr/bin/env bash
# olly-down.sh — Remove the Olly Sentinel replica namespace.
# Shared infrastructure remains intact; run olly-up.sh to restore.

set -eo pipefail

SCRIPT_DIR="$(dirname -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "${SCRIPT_DIR}" && pwd -P)"
exec "${SCRIPT_DIR}/resourceset-down.sh" olly /tmp/.olly-resourceset-inputs.json olly-replica
