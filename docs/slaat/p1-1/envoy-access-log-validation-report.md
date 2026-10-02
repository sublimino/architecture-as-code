# SLAAT-P1-1 — Envoy Gateway Access Log Validation Report

**Evidence:** `ci-evidence/slaat-p1-1-gateway-access-log-sample.jsonl` (captured
live by `scripts/envoy-gateway-audit.sh` via
`kubectl -n ingress logs -l gateway.envoyproxy.io/owning-gateway-name=cluster -c envoy --since-time=<audit start>`)

## Question

Does the Gateway's access log stream capture enough to reconstruct, after the
fact, *who* sent *what* and *why it was dropped or rejected*, for every
adversarial probe in this card?

## Finding: yes, with one structural caveat at the TLS layer

No `EnvoyProxy`/`ClientTrafficPolicy` access-log configuration exists anywhere
in this repo (`d2-infra/components/ingress/configs/base/envoy-gatewayclass.yaml`
only sets `provider.kubernetes.envoyService.type: NodePort`). Access logging
is therefore Envoy Gateway's **own default** JSON access log, emitted to the
`envoy` container's stdout — captured here via `kubectl logs`, not a
dedicated log-shipping pipeline (no Loki/Elastic sink is wired up in this
repo; see hardening checklist).

The default log line is a single JSON object per request/connection with (at
minimum) these fields, verified present in the sample:

```
:authority, method, protocol, requested_server_name, response_code,
response_code_details, route_name, upstream_cluster, upstream_host,
downstream_remote_address, start_time, user-agent, x-envoy-origin-path,
x-forwarded-for, x-request-id
```

### Client IP — captured on every log line, routed or not

`downstream_remote_address` is populated even for connections that never
complete a TLS handshake (the `filter_chain_not_found` case below has
`"downstream_remote_address": "127.0.0.1:42028"` with everything else null).
Via a real port-forward this is the port-forward's local loopback address, not
the true external client IP — in a non-dev deployment this would be the real
peer or (per §4 of the main report) the LAST, Envoy-appended hop of
`x-forwarded-for`. **Client-attributable IP is logged for every connection
attempt, including rejected ones.**

### Requested URI — captured for every request that reaches HTTP parsing

`x-envoy-origin-path` logs the **normalized** path Envoy actually routed on,
which is itself useful forensic signal (it shows what the attacker's raw path
collapsed to), e.g.:

```json
{"x-envoy-origin-path": "/admin", "response_code": 307, "response_code_details": "path_normalization_failed", "upstream_cluster": null}
```

```json
{"x-envoy-origin-path": "/api/%00/admin", "response_code": 400, "response_code_details": "path_normalization_failed", "upstream_cluster": null}
```

**Caveat:** a connection rejected at the **TLS/SNI layer** (no matching filter
chain — the `GW-VHOST-1` unregistered-SNI probe) is logged with `method`,
`:authority`, and `x-envoy-origin-path` all `null`:

```json
{"response_code": 0, "response_code_details": "filter_chain_not_found", "response_flags": "NR", "downstream_remote_address": "127.0.0.1:42028", "requested_server_name": null}
```

This is structurally correct, not a logging gap: HTTP has not been parsed yet
at the point the TLS layer rejects the connection, so there is no URI to log.
The **SNI** that was attempted would be available via `requested_server_name`
on a listener configured to log it per-filter-chain rather than only on the
HTTP connection manager; this one logs `null` because the connection is
rejected *before* the HTTP connection manager (which owns
`requested_server_name` population in this config) ever sees it. **Recommendation** in the hardening checklist: add filter-chain-level logging
(or a `drainManager`/listener-level access log) if forensic reconstruction of
rejected-SNI attempts by hostname (not just client IP) becomes a requirement.

### Rejection reason — captured via `response_code_details`

Every drop/rejection in this probe set carries a specific, machine-readable
`response_code_details`:

| Scenario | `response_code` | `response_code_details` |
| --- | --- | --- |
| Unregistered SNI | 0 | `filter_chain_not_found` |
| Encoded-slash path | 307 | `path_normalization_failed` |
| Embedded null byte | 400 | `path_normalization_failed` |
| Normal backend 404 | 404 | `via_upstream` (reached the backend; not a Gateway-level rejection) |
| Normal backend 200 | 200 | `via_upstream` |

The distinction between `path_normalization_failed` (Envoy rejected it,
`upstream_cluster: null`) and `via_upstream` (Envoy routed it, backend
answered) is exactly the signal needed to tell "the Gateway stopped this" from
"the backend's own logic returned a 404" — which is the evidence this report's
sibling (the main audit report, §2, GW-TRAV-4) relies on to prove no backend
was ever contacted for the encoded-slash traversal attempt.

### Header-spoofing evidence captured verbatim

```json
{"x-envoy-origin-path": "/api/v1/healthz", "x-forwarded-for": "1.2.3.4,10.0.0.126"}
```

Confirms the §4 claim in the main report directly: the client-supplied
`X-Forwarded-For: 1.2.3.4` is retained as the first hop, and Envoy appends the
real peer address (`10.0.0.126`, the port-forward's pod-network source) as
the trusted last hop. A backend reading `XFF[0]` instead of the last/trusted
hop would be fooled by this; one reading the last hop is not.

## Verdict

**PASS**, with one documented, structurally-correct caveat: TLS-layer
rejections log client IP and rejection reason but not a request URI (because
none has been parsed yet) and not the attempted SNI hostname (this listener's
HTTP connection manager, not the filter chain, owns that field). Both gaps
are closeable with additional Envoy listener configuration, tracked as a
hardening recommendation rather than a P1 blocker since the existing coverage
already identifies *that* an attack was attempted and from where.
