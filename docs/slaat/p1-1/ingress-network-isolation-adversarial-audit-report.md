# SLAAT-P1-1 — Ingress Gateway & Network Isolation Adversarial Audit Report

**Card:** `SLAAT-P1-1` · **Phase:** P1 · **Depends on:** `SLAAT-P1-PRE`
**Cluster:** `kind-osramp` (context `kind-osramp`), live, 31+ days up at probe time
**Generated:** see `ci-evidence/slaat-p1-1-network-findings.json` (`generated_at`)
**Scripts:** `scripts/envoy-gateway-audit.sh`, `scripts/probe-network-isolation.sh`
**Tests:** `test/adversarial-network-probes.bats` (20/20 green against the live cluster)

This report is derived entirely from the two scripts' JSON evidence, merged at
`ci-evidence/slaat-p1-1-network-findings.json`. Every claim below cites a
record ID from that manifest. Nothing here is simulated — every probe ran
against the actual deployed Envoy Gateway and actual live NetworkPolicy
objects in `kind-osramp`.

## 1. Scope and method

Two independent probe components, both read-only against already-deployed
resources (no Gateway/HTTPRoute/NetworkPolicy manifest was created, edited, or
deleted):

1. **`envoy-gateway-audit.sh`** — port-forwards the live Envoy Gateway data
   plane (`svc/envoy-ingress-cluster-6b24dc08`, discovered by label
   `gateway.envoyproxy.io/owning-gateway-name=cluster`) to a local port and
   runs 19 probes: unauthenticated virtual-host access, path traversal (plain
   and percent-encoded), encoded-slash handling, null-byte rejection,
   path-prefix ambiguity (case, trailing slash), unauthenticated header
   spoofing, TLS version/cipher enforcement (pinned min==max, not just a
   minimum-version flag), and an HTTP/2 baseline. Findings are read from
   **Envoy's own access log** (`x-envoy-origin-path`, `response_code_details`,
   `route_name`, `upstream_cluster`), not inferred from curl's exit status
   alone, because Envoy normalizes paths server-side before routing.

2. **`probe-network-isolation.sh`** — (a) a coverage pass over every namespace
   with running pods, classifying whether a `NetworkPolicy` with
   `podSelector: {}` selects *all* pods for Ingress and for Egress (the only
   shape that behaves as a genuine default-deny — narrower policies leave
   unselected pods fully open); (b) a lateral-movement pass using short-lived,
   self-deleting `busybox:1.36.1` pods (`kubectl run --rm`, pre-cached image,
   no pull) attempting raw `nc -z` TCP connects to fixed ClusterIP:port
   targets from both a strict baseline namespace and an unprotected one.

### Substitution note on the card's literal port

The card's Required Tests cite `https://localhost:31443/`. On this host,
`127.0.0.1:31443` was already bound by an unrelated, dead listener (confirmed
via `ss -ltn` plus a direct TLS/plaintext probe — every connection reset
immediately with no handshake, and the peer session that might have owned it
confirmed by cross-session message it was not theirs either). The scripts use
`SLAAT_GW_LOCAL_PORT` (default `18443`) for their own
`kubectl port-forward` instead. This is a port substitution only; the target
service, path, and header probes are unchanged from the card's intent.

## 2. Envoy Gateway findings — summary: 19/19 probes pass-or-info, 0 fail

| ID | Vector | Result |
| --- | --- | --- |
| GW-VHOST-1 | Unregistered SNI (`internal.osramp.local`) | **PASS** — rejected at the TLS layer (`filter_chain_not_found`) before any HTTP routing; connection never completes a handshake |
| GW-VHOST-2 | Correct SNI, spoofed `Host:` header | **PASS** — 404; route hostname matching is exact, no fallthrough into another tenant's HTTPRoute |
| GW-TRAV-1 | `/api/v1/../admin` (literal) | **PASS** — Envoy normalizes to `/api/admin` before routing (confirmed via access log `x-envoy-origin-path`), still inside the `/api` prefix, backend 404s cleanly |
| GW-TRAV-2 | `/api/%2e%2e/%2e%2e/etc/passwd` | **PASS** — decoded+collapsed to `/etc/passwd` before routing, matches no HTTPRoute prefix, falls to the dashboard SPA's catch-all (serves `index.html`, not a filesystem read) |
| GW-TRAV-3 | `//api` (double leading slash) | **PASS** — merged to `/api` before routing, same backend 404 as a bare request |
| GW-TRAV-4 | `/api/..%2f..%2fadmin` (encoded slash) | **PASS** — Envoy's own `path_normalization_failed` handling returns a 307 to the canonical path **without ever selecting a route or contacting a backend** (access log: `upstream_cluster=null`, `response_code_details=path_normalization_failed`). No differential parsing between Envoy and the backend was observed. |
| GW-TRAV-5 | `/api/%00/admin` (null byte) | **PASS** — 400, rejected as malformed before routing |
| GW-AMBIG-1..3 | Case sensitivity, trailing slash | **INFO** — PathPrefix matching is case-sensitive and slash-sensitive in the expected, non-exploitable way; unmatched paths fall to the public SPA, not a privileged route |
| GW-HDR-1..3 | X-Forwarded-For / X-Real-IP / X-Forwarded-Prefix spoofing | **PASS/INFO** — no HTTPRoute `matches.headers` rule in this repo reads these headers, so spoofing cannot alter routing. See §4 for a backend-trust caveat. |
| GW-TLS-1.0, GW-TLS-1.1 | Legacy TLS pinned via `--tlsv1.X --tls-max 1.X` | **PASS** — both refused (`no protocols available`); listener accepts TLS 1.2+ only |
| GW-TLS-1.2 | Pinned TLS 1.2 | **PASS** — negotiates `ECDHE-ECDSA-CHACHA20-POLY1305` (AEAD, forward secrecy) |
| GW-TLS-1.3 | Pinned TLS 1.3 | **PASS** — negotiates `TLS_AES_256_GCM_SHA384` |
| GW-H2-1 | HTTP/2 baseline | **INFO** — HTTP/2 negotiates cleanly; genuine pseudo-header-manipulation/smuggling fuzzing needs a raw-frame tool this probe set does not have (curl cannot forge invalid `:method`/`:path`/`:authority` framing independent of its own HTTP/2 library). **Coverage gap, not a clean bill of health** — flagged in the hardening checklist. |

**Zero fail-severity findings on the Gateway side.** Path normalization,
TLS enforcement, and virtual-host isolation all held under adversarial input.

## 3. Network isolation findings — summary: 10 fail-severity findings

### 3.1 NetworkPolicy coverage gaps (confirmed finding)

8 of 22 populated namespaces carry **zero** `NetworkPolicy` objects of any
kind (fully open ingress and egress by Kubernetes/Cilium default), and a 9th
(`kagent`) carries only narrow policies that leave most of its own pods
unselected:

| Namespace | Pods | Policies | Priority | Why it matters |
| --- | --- | --- | --- | --- |
| `backend` | 7 | 0 | tenant | Runs MinIO, NATS, and its own Postgres — zero isolation |
| `frontend` | 3 | 0 | tenant | Runs `osramp-archiver`, `osramp-multipurpose`, `osramp-purl` |
| `ingress` | 2 | 0 | tenant | **The Envoy Gateway control plane itself** — see LAT-9 below |
| `cpai` | 1 | 0 | tenant | `cpai-runtime` |
| `fe-k8s-afm` | 1 | 0 | tenant | `afm-platform` |
| `kagent` | 4 | 2 (narrow) | tenant | Only `kagent-postgresql` ingress is actually scoped (to `kagent-controller`); `kagent-controller`/`kagent-ui`/`kagent-tools` have no Ingress-type policy selecting them at all |
| `cert-manager`, `kube-system`, `spire-system`, `local-path-storage`, `registry` | — | 0 | **platform** | Core cluster plumbing (CNI, DNS, ACME, attestation); a blind default-deny here risks breaking the cluster and needs a scoped allowlist, not a copy of the tenant pattern — see hardening checklist |

14 of 22 namespaces (`agent-trust-*`, `default`, `eap-6f82ad81`,
`fe-signalloom`, `fe-signalloom-agents`, `flux-system`, `inf-bao`,
`inf-signalloom`, `stun-pre-probe`) correctly carry a blanket
`podSelector: {}` default-deny for both directions.

### 3.2 Lateral-movement proof (confirmed finding)

Ephemeral probe pods, labelled `slaat.controlplane.io/probe=p1-1` (distinct
from any pre-existing mission's probe label, so no unrelated carve-out policy
applies), attempted raw TCP connects. The zero-trust expectation under test
is always **blocked** — a governed namespace's workloads must not be reachable
from an arbitrary unauthenticated peer:

| ID | Source → Target | Expected | Observed | Verdict |
| --- | --- | --- | --- | --- |
| LAT-1 | `default` → `inf-signalloom/postgresql:5432` | blocked | blocked | PASS |
| LAT-2 | `default` → `kube-apiserver:443` | blocked | blocked | PASS |
| LAT-3 | `default` → `ingress/envoy-gateway:19001` (metrics) | blocked | blocked | PASS |
| LAT-4 | `frontend` → `backend/minio:9000` | blocked | **reachable** | **FAIL** |
| LAT-5 | `frontend` → `backend/nats:4222` | blocked | **reachable** | **FAIL** |
| LAT-6 | `frontend` → `backend/postgres:5432` | blocked | **reachable** | **FAIL** |
| LAT-7 | `frontend` → `inf-signalloom/postgresql:5432` | blocked | blocked | PASS |
| LAT-8 | `frontend` → `inf-signalloom/redis:6379` | blocked | blocked | PASS |
| LAT-9 | `frontend` → `ingress/envoy-gateway:19001` (metrics) | blocked | **reachable** | **FAIL** |

LAT-1/2/3 prove the strictest case (a pod with a blanket default-deny and no
extra grant) cannot reach anything, not even the Kubernetes API server
ClusterIP. LAT-7/8 prove defense-in-depth: even a source namespace with *no*
egress restriction at all is still stopped by the *target* namespace's ingress
policy. LAT-4/5/6/9 prove the converse — where **neither side** has a policy,
traffic flows freely, exactly matching the card's named failure mode
("Missing DefaultDeny NetworkPolicies in application namespaces allowing
unrestricted pod-to-pod east-west traffic").

### 3.3 Control-plane exec channel (informational, not a network-path result)

`kubectl -n inf-signalloom exec deployment/postgresql -- pg_isready` returns
`accepting connections` (PGREADY-1). This is the Required Test named
verbatim on the card. It is included for completeness but **does not bypass
or test NetworkPolicy** — `kubectl exec` runs over the API-server→kubelet exec
stream, not the pod network, so it says nothing about network isolation and
must not be read as such.

## 4. Additional observations (not separately scored)

- **No `ClientTrafficPolicy` is configured anywhere in this repo.** Envoy
  Gateway's default XFF behaviour is to *append* the real peer address rather
  than trust or replace a client-supplied value, so a client-supplied
  `X-Forwarded-For` entry is not authoritative but is still present in the
  header chain a naive backend could misread as `XFF[0]`. See hardening
  checklist.
- **HTTP/2 pseudo-header smuggling was not exhaustively tested** (GW-H2-1) —
  genuine coverage requires a raw-frame HTTP/2 client, which was out of reach
  of this probe set's toolchain (curl only).
- **Access logging is enabled by Envoy Gateway's own default** — see the
  companion `envoy-access-log-validation-report.md` for the specific fields
  verified.

## 5. Verdict

| Surface | Fail-severity findings |
| --- | --- |
| Envoy Gateway (routing, TLS, path normalization, header spoofing) | **0** |
| NetworkPolicy microsegmentation | **10** (6 namespace coverage gaps + 4 lateral-movement confirmations) |

The Gateway's own request-handling held cleanly under every adversarial input
tried. The network-isolation boundary is **not** uniformly zero-trust: two
genuinely unprotected tenant namespaces (`backend`, `frontend`) can reach each
other and reach the Gateway's own metrics port with no authentication at all.
Remediation is tracked in `network-hardening-checklist.md` for the P2
fail/fix phase (`SLAAT-P2-1`).
