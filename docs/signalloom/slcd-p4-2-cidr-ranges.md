# SLCD-P4-2 — Inference Provider Range List

> **Purpose.** The committed, versioned, reviewable source of truth for which destination
> addresses may be attributed to which inference provider. Before this card, no such list
> existed anywhere in the tree, which is why the proposal's "zero false positives" KPI had
> never been measurable: there was nothing to measure against.
>
> | | |
> |---|---|
> | **Artefact** | `d2-signalloom/apps/agentmaxxing-host-sensor/data/inference_providers.json` |
> | **List version** | `2026-09-15.1` |
> | **Consumer** | `network.InferenceProviderRanges` |
> | **Review doc** | this file |
> | **Card** | `SLCD-P4-2` |

---

## 1. Why the list is tiered

The proposal says to match "destination IPs against known inference provider CIDR ranges".
Taken literally that is unsound, and the reason is not subtle: **two of the three cloud
providers named have no dedicated address space at all.**

- `api.openai.com` resolves into Cloudflare's shared anycast estate. Cloudflare fronts a
  large fraction of the public web. Matching Cloudflare's published ranges attributes every
  Cloudflare-fronted site on the host to OpenAI.
- `aiplatform.googleapis.com` and `generativelanguage.googleapis.com` are served from Google
  Cloud load-balancer and Google edge space shared with Search, Drive, YouTube and every
  GCP-hosted third-party service.

This is not a theoretical concern. Measured on the target host on 2026-09-15:

| Observed destination | Inside which provider range | What it actually was |
|---|---|---|
| `35.186.224.33:443` | Google Cloud (`35.186.224.0/20`) | a music streaming client |
| `104.21.23.165:443` | Cloudflare (`104.16.0.0/13`) | a web browser |
| `172.67.212.85:443` | Cloudflare (`172.64.0.0/13`) | a web browser |
| `160.79.104.10:443` | Anthropic (`160.79.104.0/23`) | a coding agent — a true positive |

Every range therefore carries an `attribution` tier, and the tier is load-bearing logic in
`network.SocketDetector.classify`, not descriptive metadata:

| Tier | Meaning | Sufficient alone? |
|---|---|---|
| `dedicated` | operated by the provider, carries no unrelated third-party traffic | **yes** |
| `loopback` | local runtime on a reserved, non-shared port | **yes** |
| `shared` | shared CDN or shared cloud front-end space | **no** — requires a harness process in the socket's cgroup |

A `shared` match with no corroboration classifies as `unknown`. It is never resolved to the
nearest provider.

---

## 2. Provider entries and provenance

### anthropic — `api.anthropic.com` — *inference*

- **Ranges:** `160.79.104.0/23`, `2607:6bc0::/48` — both `dedicated`.
- **Source:** <https://docs.anthropic.com/en/api/ip-addresses>
- **Provenance:** Anthropic is the only provider in this list that publishes a dedicated
  ingress range for its API. Confirmed live on the host: 21 concurrent established sockets to
  `160.79.104.10:443` from a coding-agent cgroup, 56 MB cumulative egress.
- **Consequence:** Claude Code traffic is attributable on address and port alone. This is the
  only cloud provider here for which that is true.

### openai — `api.openai.com` — *inference*

- **Ranges:** Cloudflare's published IPv4 and IPv6 list, 16 prefixes — all `shared`.
- **Source:** <https://www.cloudflare.com/ips-v4>, <https://www.cloudflare.com/ips-v6>
- **Provenance:** OpenAI publishes crawler ranges (`gptbot.json`, `chatgpt-user.json`) but
  those are *outbound* crawler egress, not API ingress, and using them here would be a
  category error. There is no published dedicated range for `api.openai.com`.
- **Consequence:** OpenAI cannot be identified by address alone. Ever. Corroboration is
  mandatory and the tier encodes that.

### google-vertex — `aiplatform.googleapis.com` — *inference*
### google-generativelanguage — `generativelanguage.googleapis.com` — *inference*

- **Ranges:** GCLB and Google edge prefixes — all `shared`.
- **Source:** <https://www.gstatic.com/ipranges/cloud.json>, <https://www.gstatic.com/ipranges/goog.json>
- **Provenance:** the Spotify/Antigravity pair measured above is the empirical basis for the
  tier. Both sit in Google space; only one is inference.
- **Note:** listed as two providers sharing overlapping ranges so the *emitted identifier*
  distinguishes Vertex from the Gemini API. The ranges do not differ; the product does.

### ollama — `ollama.localhost` — *inference*

- **Ranges:** `127.0.0.0/8`, `::1/128` on port `11434` — `loopback`.
- **Source:** Ollama's default `OLLAMA_HOST` bind.
- **Provenance:** port 11434 is reserved to Ollama by convention and nothing else on the
  target host binds it, so address + exact port is an exclusive signal.

### local-openai-compatible — `vllm.localhost` — *inference*

- **Ranges:** `127.0.0.0/8`, `::1/128` on port `8000` — **`shared`, deliberately.**
- **Provenance:** vLLM, llama.cpp and LM Studio conventionally bind loopback:8000, but 8000 is
  also the single most common generic dev-server port. Tiering this `loopback` would have made
  every local web server an inference endpoint. It is tiered `shared` despite being loopback,
  which is the one place in this list where the tier name and the address family disagree —
  intentionally, because the tier encodes exclusivity, not address class.

### openbao — `openbao.localhost` — *control-plane, NOT inference*

- **Ranges:** `127.0.0.0/8`, `::1/128` on port `8200` — `loopback`.
- **Provenance:** OpenBao is a secrets manager. It appears in the SLCD-P4-2 card's provider
  list, so it is recorded here to show it was considered rather than overlooked.
- **Consequence:** `kind: control-plane` entries are excluded from
  `InferenceProviderRanges.inference_endpoints` and can never be emitted as
  `network.inference_endpoint`. Reporting a secrets-manager connection as model egress would
  be a fabricated finding, and the exclusion is enforced in code and pinned by
  `test_openbao_connection_is_classified_control_plane_never_inference`.

---

## 3. Maintenance

Provider ranges change. The artefact carries `list_version` and `generated` so a stale list is
visible rather than silent, and `InferenceProviderRanges.from_dict` raises on an unrecognised
attribution tier so a new range cannot be added without a reviewer choosing its tier.

**When adding a range, the question to answer is not "does the provider use it" but "does
anyone else use it too".** A range that carries third-party traffic is `shared`, however
strongly it is associated with the provider. Getting that wrong is how the measured
false-positive rate in `slcd-p4-2-socket-detector.md` regresses.
