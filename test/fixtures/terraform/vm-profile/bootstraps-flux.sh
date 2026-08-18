#!/usr/bin/env bash
# Fixture: a startup script bootstrapping GitOps. Must be caught.
set -euo pipefail
flux bootstrap git --url=ssh://git@example.invalid/repo
