# Security Sandbox

Defence in depth for the Olly agent, and a red-team harness to prove it works.

Two layers guard the agent traffic in this estate:

1. **The deterministic redactor** (`apps/sentinel/olly_sentinel/redact.py`). Fixed
   regex patterns strip secret- and PII-shaped strings from every log line
   before the agent narrates them, and from every field the agent publishes. It
   is always on and cannot be argued out of a match by a hostile log line. This
   is the hard control.

2. **LLM Guard** (this app). An in-cluster, model-based scanner that is the
   second opinion on the agent's A2A traffic. It catches the shapes a regex
   cannot: a novel prompt injection, model-detected PII, a malicious URL in a
   reply. It runs the lightweight scanner set from the `research-ai-red-teaming`
   R&D (Secrets, Anonymize, PromptInjection, Toxicity, Gibberish on input;
   Sensitive, MaliciousURLs, NoRefusal, Deanonymize, Toxicity, Gibberish on
   output).

The thesis the sandbox demonstrates: **output from one model is untrusted input
to the next.** An instruction an attacker plants in a log line is carried by the
redactor as harmless data, but if it rode unscanned across an agent-to-agent
hand-off it could steer the next agent. LLM Guard is where that steering is
caught before the downstream agent sees it.

## Pieces

| Piece | Where | Role |
|---|---|---|
| LLM Guard pod | `components/configs/base/llm-guard.yaml`, image `apps/llm-guard/` | The scanner, in-cluster on `:8000`. `/analyze/prompt` and `/analyze/output`. |
| Olly -> Orbit hop | `apps/sentinel/olly_sentinel/guard.py` + `main.py` | When `LLM_GUARD_ENABLED=true`, Olly scans the message it sends Orbit (input) and Orbit's reply (output). A tripped scan holds the hand-off and emits `gate=llm_guard` on the decision bus. |
| Broker gateway | `tools/demo-console/security.go` | `/api/security/{status,scan,probe}`. The probe forwards a message to the live Olly agent with the guard on or off. |
| Estate 95 app | `ui/windows/security-sandbox.js` | Scan any string live, probe the agent guarded vs unguarded, launch the red-team. |
| promptfoo driver | this directory | Generates attacks and grades Olly's replies through the probe endpoint. Web UI on `:3000`. |

The redactor and LLM Guard are independent layers: the guard being off (the
default) does not weaken the redactor, which always runs.

## Run it

**1. Build and deploy the scanner pod** (heavy image: torch + ONNX + scanner
models). It is part of the GitOps kustomization, so `make push-local` reconciles
it; for a quick local iteration:

```
make -C olly-replica llm-guard-build
kubectl -n olly-replica apply -f olly-replica/components/configs/base/llm-guard.yaml
kubectl -n olly-replica rollout status deploy/llm-guard --timeout=600s
```

Models load at pod startup, so the first boot takes a few minutes; after that,
scans are fast. A kind node needs headroom (Docker Desktop 8GB+).

**2. Toggle the guard on the Olly -> Orbit hop** (optional; off by default):

```
kubectl -n olly-replica set env deploy/olly-sentinel LLM_GUARD_ENABLED=true
```

**3. Drive it from Estate 95.** Open the **Security Sandbox** app (the 🛡️ icon).
Scan a string, or probe the agent with the guard on and off and watch a blocked
message never reach Olly.

**4. Red-team the agent with promptfoo.** The web UI runs on `:3000`.

```
cd olly-replica/apps/security-sandbox
cp .env.example .env          # add an OpenRouter / OpenAI / Anthropic key
make -C ../.. security-sandbox-up          # or: docker compose up -d
./redteam.sh baseline         # LLM Guard OFF (attack-success baseline)
./redteam.sh guarded          # LLM Guard ON  (defended)
```

Open http://localhost:3000 and compare the two runs. The baseline is the
attack-success rate against the raw agent; the guarded pass shows how much the
scanner removes.

## How the pieces connect

```
promptfoo (:3000) ──POST /api/security/probe {message, llm_guard_enabled}──▶ console broker (:8675)
                                                                                   │
                                              llm_guard_enabled ─┬─ scan input ──▶ LLM Guard pod (:8000)
                                                                 │
                                                                 └─ forward ─────▶ Olly A2A (:8080, read-only triage)
                                                                                   │
                                                                     scan output ◀─┘
```

The same LLM Guard pod backs both the live Olly -> Orbit hop (inside the
sentinel) and the red-team probe (through the broker), so what promptfoo
measures is the same scanner that protects the running pipeline.

## Local-setup caveats

- The guard is deployed as one replica with an `emptyDir` model cache, so a
  fresh pod re-downloads its models. Fine for a demo, not a production topology.
- The scan API bearer token is a fixed local value (`llm-guard-token`), not a
  managed secret. In ARC this is a COIN M2M credential.
- promptfoo's attack generation and grading call an external LLM provider; no
  estate data leaves the machine, only the synthetic red-team prompts do.
