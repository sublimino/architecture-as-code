# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/eap_contract.py
# Early Access Program (EAP) lifecycle and tenancy contract constants.
#
# Proposal reference:
# - Proposal — Signal Loom EAP Certification Remediation (2026-Q3).md
#   - Row P3-2 (Single MAX_LIFETIME_HOURS constant & TTL ceiling)
#   - SP-P3-1, SP-P3-3, SP-P3-4
# ==============================================================================
"""Authoritative EAP contract constants.

Single source of truth for lifecycle ceilings, initial TTL bounds, heartbeat
windows, and workload identity trust domains across Signal Loom EAP modules.
"""

#: Maximum total environment lifetime ceiling (8 hours).
#: Proposal row P3-2 (Single MAX_LIFETIME_HOURS constant) & SP-P3-3.
MAX_LIFETIME_HOURS = 8

#: Maximum initial TTL request in minutes (480 minutes / 8 hours).
#: Proposal row P3-2 (Pin MAX_INITIAL_TTL_MINUTES to spec) & SP-P3-3.
MAX_INITIAL_TTL_MINUTES = 480

#: Heartbeat window duration in seconds (300 seconds / 5 minutes).
#: Proposal row P3-2 & SP-P3-3.
HEARTBEAT_WINDOW_SECONDS = 300

#: Authoritative SPIFFE trust domain for Signal Loom workload identity.
#: Proposal row P3-1 (Live Identity Plane) & SP-P3-1.
SPIFFE_TRUST_DOMAIN = "signalloom.demo"
