#!/usr/bin/env bash
# Fixture: a startup script that drives a demo make target. Must be caught.
set -euo pipefail
cd /opt/osramp && make demo-up
