# Sandbox risks in the data Nono outputs

This page is the security register for the *output* of the nono (Landlock)
sandbox as the platform consumes it — the `HostAssertionEnvelope` / `NonoAuditEvent`
stream that the `agentnono` collector turns into observations. It was produced
while standing up a second Kusari agent (`agent-nono-kusari`) under nono
enforcement; deploying a *second* emitter is what surfaced several of these.

The governing idea: **the output of a security control is itself attack
surface.** Nono's evidence names denied paths, is uploaded over a wire, is
verified, and drives detection — so every one of those steps can mislead, leak,
or be forged. This register NAMES the risks with evidence; fixes are a follow-up.

## The headline: emitted "enforcement" is not the same as enforcement

The repo's nono integration is a demo abstraction. Two concrete places where the
*output* claims enforcement that did not necessarily happen:

- `d2-signalloom/apps/nono-containment-probe/Dockerfile` ships a **shim** `nono`
  (`printf '#!/bin/sh ... exec "$@"'`) that strips args to `--` and execs the
  command **with no Landlock applied**, while the entrypoint still reads
  `nono --profile .../probe.toml --`. The assertion stream looks identical to real
  enforcement.
- `d2-signalloom/infra/agent-swarm/agent-nono-evidenced/configmap.yaml` (SP-5)
  emits `nono_capability_available:false` and then keeps sending
  `status:"healthy"` heartbeats while **executing unconfined**.

A consumer reading only the assertion stream cannot tell enforced from
unenforced. **`agent-nono-kusari` no longer inherits this: it runs the real
nono binary (nono.sh v0.79.0) via `Dockerfile.nono`, verified end-to-end** —
`/act/read-shadow` returns a real `open /etc/shadow: permission denied` both
in a local container and live on kind-osramp (agent log), under
`seccompProfile: RuntimeDefault` with all capabilities dropped, and the
`test/kusari-nono-enforcement.bats` suite asserts the kernel deny/allow
directly. R3 below therefore now scopes to the `nono-containment-probe` shim
Dockerfile and the `agent-nono-evidenced` SP-5 fallback, which remain demo
abstractions — this agent is the real reference.

## Risk register

| # | Risk | Likelihood | Impact | Evidence | Mitigation | Status |
|---|------|-----------|--------|----------|------------|--------|
| R1 | **Path leakage** — denied-path strings ride into observations in cleartext, revealing filesystem layout and exact secret locations the agent probed (`/etc/shadow`, `/etc/kubernetes/admin.conf`). The eBPF sentinel digests `target`; this path does not. | High | Med | `collectors/agentnono/collector.go:283` (`obs.Labels["path"]=event.Path`) vs sentinel `targetDigest` | Digest/redact `labels.path` as the sentinel does, or gate it behind the same redaction as `target`. | OPEN |
| R2 | **ABI / capability downgrade** — an envelope can assert enforcement while the actual Landlock ABI is low or the restriction is a no-op; `LandlockEnforced` is a separate bool from the claim. | Med | High | `apps/nono-containment-probe/probes.go:18` (`LandlockEnforced bool`), verifier ABI test (`verifier_test.go:197`) | Reject evidence whose claimed ABI < policy floor AND require `LandlockEnforced==true`; bind the claim to a measured ABI. | PARTIAL |
| R3 | **Optionality / unconfined fallback** — the sandbox is absent yet healthy heartbeats and `sandboxing:landlock` evidence still flow (SP-5 + the shim). The most dangerous property: "evidence of enforcement" with no enforcement. | High | High | `agent-nono-evidenced/configmap.yaml` SP-5 block; `nono-containment-probe/Dockerfile` shim | Fail-closed (as `agent-nono-kusari` does); treat `nono_capability_available:false` as an ALERT, never a healthy state. | OPEN (by design in the demo) |
| R4 | **Overclaim** — the envelope/ack claims more evidence than it carries (`original_chain_reference.event_count` vs `len(assertions)`). | Low | Med | `collectors/agentnono/external_contract_test.go:42` ("upload acknowledgement overclaims evidence") | Enforce `event_count == len(assertions)` at ingest (the contract test already pins the ack case). | BLOCKED (contract test present) |
| R5 | **Sequence gap / replay** — a dropped denial is a silent `sequence` gap that reads as "no attack"; a replayed envelope double-counts or masks. Chain continuity catches tamper/replay, not DROPS. | Med | High | `collectors/agentnono/verifier.go:212` (`verifyHashChain`), `external_contract.go` (`ReplayKey`, `maxWireSequence`) | Alert on sequence discontinuity (gap), not only on chain break; treat a gap as a potential suppressed denial. | PARTIAL (tamper/replay blocked; gap open) |
| R6 | **Identity spoof** — a denial attributed to a SPIFFE the emitter does not hold. Blocked when the SVID is checked against the trust pool; weakens to signature-only when no pool is configured. | Low | High | `collectors/agentnono/verifier.go:157-205` (SAN + trust-pool path; `signature present but issuing certificate was omitted`) | Require SVID + trust pool; reject signature-only evidence in a deployed estate. | PARTIAL |
| R7 | **Deny-as-information oracle** — the agent uses allow/deny outcomes (incl. `nono why`) to enumerate which paths the profile permits, mapping the sandbox from inside. | Med | Med | real `nono` CLI `why` subcommand; per-path deny evidence naming the attempted path | Don't expose `nono why` to the workload; alert on deny-enumeration bursts (the sentinel evasive-burst analogue). | OPEN |
| R8 | **Source misattribution** — the collector hardcodes `Source:"agent-nono-evidenced"`, so a *second* agent's denials (`agent-nono-kusari`) are laundered under the first agent's identity. Surfaced directly by deploying a second emitter. | High | Med | `collectors/agentnono/collector.go:255` (`Source: "agent-nono-evidenced"`) | Derive `Source` (and tenant) from the verified `event.AgentID`/SPIFFE, never a constant. | OPEN |

## What the current verifier already blocks vs. what is open

- **Blocked**: signature tamper, hash-chain break, replay of a tampered chain,
  unknown/aliased/duplicate evidence keys (strict decode), ack overclaim (R4).
- **Open / partial**: cleartext path leakage (R1), ABI downgrade (R2),
  unconfined-but-healthy (R3), sequence *gaps* i.e. suppressed denials (R5),
  signature-only when no trust pool (R6), deny-oracle enumeration (R7), and
  source misattribution across multiple agents (R8).

## Follow-up (not built here)

Post-enforcement *response* — what the platform should DO when a nono denial is
observed (alert, quarantine, correlate with the sentinel's eBPF view of the same
agent) — is deferred, mirroring the first task. R1/R3/R8 are the cheapest, highest
-value fixes and are the recommended first follow-up.
