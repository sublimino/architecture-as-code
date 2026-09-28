# Mutation evidence, EAPR-P2-1 (2026-09-24 18:46:08 +0100)

Runner: SP-1 uv/pytest over tests/test_tenant_isolation.py; each mutant applied with sed/python, run, restored (git diff --quiet confirmed).

## T7 — remove dependencies= from one mount at a time, behavioural probes only (-k every_eap_route_is_bound)
```text
mutant tenant_isolation (mount without dependencies): sealed sweep -> 34 passed
mutant scenario_seeding (mount without dependencies): sealed sweep -> 34 passed
mutant environment_routing (mount without dependencies): sealed sweep -> 34 passed
mutant environment_lifecycle (mount without dependencies): sealed sweep -> 5 failed, 29 passed
mutant webhook_triggers (mount without dependencies): sealed sweep -> 34 passed
```
Four of five survived: every handler takes tenant via authenticated_tenant, which pulls authenticated_principal in by parameter. The mount is therefore asserted structurally:

## T7 — same five mutants, structural assertion (-k carries_the_mount)
```text
mutant tenant_isolation: 1 failed | first named: APIRoute /api/v1/eap/tenants;APIRoute /api/v1/eap/tenants
mutant scenario_seeding: 1 failed | first named: APIRoute /api/v1/eap/scenarios/events/{customer_hash};APIRoute /api/v1/eap/scenarios/events/{customer_hash}/stream
mutant environment_routing: 1 failed | first named: APIRoute /api/v1/environments/;APIRoute /api/v1/environments/provision
mutant environment_lifecycle: 1 failed | first named: APIRoute /api/v1/eap/lifecycle/active;APIRoute /api/v1/eap/lifecycle/audit-events
mutant webhook_triggers: 1 failed | first named: APIRoute /api/v1/webhooks/generic;APIRoute /api/v1/webhooks/github
```

## T5 — reinstate an X-SPIFFE-ID read in api_tenant_decrypt (SLET B1 site)
```text
unmutated: 35 passed
mutant a (header read reinstated, middleware present): 1 failed, 34 passed
  behavioural only: 34 passed
mutant b (header read + strip disabled), behavioural only: 1 failed, 33 passed
```
Mutant a is neutralised by IdentityHeaderStripMiddleware (behavioural green) and caught by the source guard; mutant b (strip disabled as well) is caught behaviourally on the decrypt route.
