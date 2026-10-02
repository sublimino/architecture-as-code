# SLAAT-P2-1 -- Network Microsegmentation Hardening Report

**Evidence:** `ci-evidence/slaat-p2-1-network-remediation.json` (consolidated),
`ci-evidence/slaat-p2-1-repro-network-isolation.json` (raw probe replay),
`test/network-microsegmentation-hardening.bats` (14/14 pass),
`test/adversarial-network-probes.bats` (21/21 pass, replayed post-fix).

## Scope note: the card's named namespaces were already fixed

The card's Objective/Deliverables name `inf-signalloom`, `fe-signalloom`, and
`fe-signalloom-agents` as the namespaces needing DefaultDeny and PostgreSQL
microsegmentation. Live inspection at the start of this card found all three
already carry a blanket default-deny plus narrow, port-scoped allows
(`inf-signalloom`'s `allow-dependency-traffic` already restricts Postgres
`5432` to `fe-signalloom`/`signal-ingest` specifically) -- this matches
SLAAT-P1-1's own "Confirmed-clean" list and SLAAT-P2-PRE's live reproduction.
Nothing in this card changes those three namespaces' NetworkPolicies.

The actual NET-1/NET-2/NET-3 findings from SLAAT-P1-1's hardening checklist
are in **different** namespaces: `backend`, `frontend`, and `ingress`
(plus an advisory-tier gap in `kagent`). This report, and the manifest
changes below, address those.

## What was fixed, and where

| Namespace | File | Before | After |
| --- | --- | --- | --- |
| `backend` | `d2-osramp-apps/components/backend/base/networkpolicy.yaml` (new) | Zero NetworkPolicy objects (NET-2); every pod open to every namespace | Blanket `podSelector: {}` default-deny (Ingress+Egress) + explicit allows: intra-namespace, DNS, `frontend`→nats:4222, `frontend/osramp-archiver`→postgres:5432, `fe-signalloom`→archivista:8082 |
| `frontend` | `d2-osramp-apps/components/frontend/base/networkpolicy.yaml` (new) | Zero NetworkPolicy objects (NET-3) | Blanket default-deny (Ingress+Egress); zero ingress rules (the three workers expose no port and no Service); scoped egress to DNS, `backend`/nats, `backend`/postgres (archiver only) |
| `ingress` | `d2-infra/components/ingress/configs/base/networkpolicy.yaml` (new) | Zero NetworkPolicy objects; Gateway metrics port (19001) reachable from any unprivileged tenant pod (NET-1 / LAT-9) | Ingress-only restriction: envoy-gateway's control ports (18000/18001/18002/19001/9443) and the proxy's metrics port (19001) same-namespace only; data-plane listeners (10080/10443) stay open to the world. **Egress deliberately untouched** -- see rationale below. |
| `kagent` | `d2-signalloom/infra/kagent/base/networkpolicy.yaml` (appended) | `kagent-controller`, `kagent-ui`, and the `kagent-tools-metrics` port (8085) had no Ingress-type policy at all | Three new Ingress-only NetworkPolicies close exactly those three gaps. **Egress deliberately untouched** -- same rationale as `ingress`. |
| Gateway (`cluster`) | `d2-infra/components/ingress/configs/base/clienttrafficpolicy.yaml` (new) | No `ClientTrafficPolicy` configured; a client-supplied `X-Forwarded-For`/`X-Real-IP` rode along in the header chain even though Envoy's default XFF handling already ignored it | `earlyRequestHeaders.remove` strips both headers before Envoy's own manipulation; `clientIPDetection.xForwardedFor.numTrustedHops: 1` declares the one-hop trust boundary explicitly |

## Why `ingress` and `kagent` are Ingress-only, not a full default-deny

Both namespaces host a Kubernetes **controller**, not a pure application
workload:

- `envoy-gateway` (namespace `ingress`) watches `Gateway`/`HTTPRoute`/etc.
  across the entire cluster via the k8s apiserver, and its data-plane proxy
  (`envoy-ingress-cluster-*`) forwards traffic to backends in every namespace
  the `Gateway`'s `allowedRoutes` permits (`fe-signalloom`, `fe-k8s-afm`,
  `ingress` itself today -- and whatever is added next, since this platform
  is designed for new tenants to onboard routes over time).
- `kagent-controller` (namespace `kagent`) runs with `WATCH_NAMESPACES=""`
  (watches every namespace) and its model-config egress target is not
  something this card can safely enumerate.

A blanket Egress default-deny on either namespace needs a hand-maintained
allowlist of the k8s apiserver's ClusterIP, every current and future routed
backend, and (for kagent) whatever model endpoint `default-model-config`
resolves to. Getting that allowlist wrong risks exactly the card's own named
hard-blocker -- "Permanent loss of cluster DNS resolution or API server
connectivity" -- and exactly the failure mode the card lists as expected --
"Envoy Gateway filter configuration syntax errors causing gateway pod
restart loops or route outages." The demonstrated attack (LAT-9: an
unprivileged tenant pod reading Envoy's metrics with no authentication) is an
**Ingress** finding; restricting Ingress alone closes it without that risk.

## Why Cilium's kubelet-probe exemption made the rest safe

Before applying anything, this card confirmed empirically (not just by
assumption) that kubelet HTTP-probe traffic is exempted from this cluster's
Cilium NetworkPolicy enforcement, independent of whether a probe's own port
is named in an explicit allow rule:

- `inf-signalloom/dex` has an `httpGet` liveness/readiness probe on its own
  `http` (OIDC, 5556) port, which `allow-dex-oidc` scopes to
  `fe-signalloom`/`ingress` namespaces only -- not to the node/kubelet. Zero
  restarts in 32 days.
- The Envoy proxy pod's own readiness probe (port 19003) is **separate** from
  the metrics port (19001) this card restricts, confirmed via
  `kubectl get pod -o json` before writing any policy -- so this was never
  actually at risk, but the dex evidence generalizes the pattern.

This is why the `backend`/`frontend` default-deny policies do not need any
special probe-port carve-out, and why restricting `ingress`'s 19001/18000-2/9443
and `kagent`'s 8083/8080/8085 does not touch kubelet's own `19003`, `19002`,
or `8081` health-check ports.

## Deliberately out of scope: `cpai`, `fe-k8s-afm`

SLAAT-P1-1's checklist also flagged `cpai` and `fe-k8s-afm` (single-pod
namespaces, advisory-tier) as carrying zero NetworkPolicy coverage. Both
live in `d2-cpai/` and `d2-k8s-afm/` respectively -- neither is `d2-infra/`
nor `d2-signalloom/infra/`, so both are outside this card's merge boundary.
Left as a backlog item, same treatment SLAAT-P1-1 gave the platform-plumbing
namespaces (`cert-manager`, `kube-system`, etc.): a dedicated, lower-urgency
follow-up rather than a blind fold-in.

## Verification

- `kubectl kustomize` succeeds for all four touched trees.
- `kubectl apply --dry-run=server` succeeds for every new object, including
  the `ClientTrafficPolicy` CRD.
- `kubectl apply --dry-run=client -k d2-signalloom/infra/inf-signalloom/configs/base`
  still succeeds (shared-file collision check named on the card).
- Applied live to `kind-osramp`: zero pod restarts across `backend`,
  `frontend`, `ingress`, and `kagent` after applying; `Gateway` stays
  `Accepted`/`Programmed`; `ClientTrafficPolicy` reports `Accepted` against
  the Gateway with no warnings.
- `test/network-microsegmentation-hardening.bats`: 14/14 pass (7 hermetic
  manifest-shape assertions, 4 live precision probes proving the fix is
  neither too loose nor too tight, 1 live end-to-end XFF-strip proof, 2
  structural/arity checks).
- `test/adversarial-network-probes.bats` (SLAAT-P1-1's own suite, replayed):
  21/21 pass. Three assertions were updated from `FINDING` (vulnerable) to
  `FIXED` (remediated) to match the new live state; one new test
  (`LAT-5 ... still works after remediation`) was added to prove the fix
  didn't also break the one legitimate cross-namespace path
  (`frontend`→`backend`/nats).
- `scripts/probe-network-isolation.sh` replay: 5 of 32 records still read
  `fail` under the script's blunt "blanket `podSelector: {}` for both
  Ingress and Egress" heuristic -- all five are the namespaces/path discussed
  above (`cpai`, `fe-k8s-afm`, `ingress`, `kagent`, and `LAT-5` itself, which
  is the intentional nats allow). None represent an un-remediated finding.
