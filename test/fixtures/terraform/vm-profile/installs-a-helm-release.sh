#!/usr/bin/env bash
# Fixture: a startup script installing a release. Must be caught.
set -euo pipefail
helm upgrade --install signalloom ./chart
