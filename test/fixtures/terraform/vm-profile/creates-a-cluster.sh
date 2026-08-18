#!/usr/bin/env bash
# Fixture: a startup script that builds the cluster. Must be caught.
set -euo pipefail
kind create cluster --name signalloom
