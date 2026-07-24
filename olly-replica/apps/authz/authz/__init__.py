"""olly-authz: the in-cluster ARC identity chain for the replica.

A small stdlib control plane that stands in for the enterprise ARC services the
client runs, deployed as a real service Olly, Orbit, and the MCP call over the
network (not a standalone demo):

    COIN issuer  (:8001)  OAuth2 H2M -> M2M-enhanced token exchange (OBO)
    PlainID PDP  (:8002)  Rego-style policy decision at issuance
    EEMS PIP     (:8003)  entitlement attributes (has_<action>_access, limits)

The token COIN mints preserves the human ACME id as ``username`` through every
hop and anchors the chain with one ``authz_ctx_id``; the A2A hop narrows it
(never widens). See olly-replica/agentic-sre-design-doc.md Part II.
"""
