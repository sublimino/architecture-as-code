#!/usr/bin/env bash
# Inverse control. Every forbidden verb appears here and every one of them is a
# comment, exactly as the real script's header documents the split it keeps:
#
#   kind create cluster --name signalloom
#   make demo-signalloom-up
#   helm upgrade --install signalloom ./chart
#   flux bootstrap git --url=ssh://git@example.invalid/repo
#
# The guard must report NOTHING here. A guard that fires on prose would call
# the correctly-written script broken and be switched off within a week.
set -euo pipefail
echo "installs prerequisites only"  # deployment is the pipeline's job
