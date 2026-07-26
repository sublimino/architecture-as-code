#!/usr/bin/env bash
# osramp-down.sh — Remove OSRAMP frontend and backend namespaces.
# Shared infrastructure remains intact; run osramp-up.sh to restore.

set -eo pipefail

SCRIPT_DIR="$(dirname -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "${SCRIPT_DIR}" && pwd -P)"
exec "${SCRIPT_DIR}/resourceset-down.sh" apps /tmp/.osramp-resourceset-inputs.json frontend backend
