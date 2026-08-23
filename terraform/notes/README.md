# Terraform build notes — index

This directory holds the hand-off notes from each chunk of the Terraform
estate's construction. **Most of it is a historical record.** Each note states
what its chunk built at the time. The notes are kept for the reasoning, not as
a description of the tree today.

Read this index before you read any file here. A note can describe a module
that no longer exists. Such a note is still worth reading for why the module
was built. It is not a source of truth about the current tree.

## Current sources of truth

Use these when you want to know what the estate does **now**:

| Question | File |
| :--- | :--- |
| What do the Terraform roots guarantee each other? | [`../CONTRACT.md`](../CONTRACT.md) |
| How is the estate laid out, and why three roots? | [`../README.md`](../README.md) |
| How do I stand a lane up, from zero? | [`../../docs/gcp-demo/RUNBOOK.md`](../../docs/gcp-demo/RUNBOOK.md) |
| How do I operate and debug the four lanes? | [`../../docs/gcp-demo/OPERATIONS.md`](../../docs/gcp-demo/OPERATIONS.md) |
| What does a module take and return? | `../modules/<name>/README.md` |
| What is the ideal state, and what is verified? | [`../ISA.md`](../ISA.md) |

## The series

| File | Chunk | Status | What it records |
| :--- | :--- | :--- | :--- |
| [`f1-foundation.md`](f1-foundation.md) | F1 | historical | The bootstrap root, version pins, and the state-protection tests |
| [`f2-envmodel.md`](f2-envmodel.md) | F2 | historical | The environment-contract module and the per-environment roots |
| [`f3-network-compute.md`](f3-network-compute.md) | F3 | historical | The network and compute modules, and five defects found in review |
| [`f4-edge.md`](f4-edge.md) | F4 | historical | The public security boundary that replaced the ngrok tunnel |
| [`f-identity-ci.md`](f-identity-ci.md) | F5 | **historical, partly superseded** | Identity and CI lifecycle. `modules/ci-runner/` no longer exists. |
| [`f-obs-make-docs.md`](f-obs-make-docs.md) | F6 | historical | Observability, the platform root, the Make lifecycle, CI and docs |
| [`g-iap-private-edge.md`](g-iap-private-edge.md) | G1 | historical | Extending the edge so a lane is routable but not publicly accessible |
| [`g-demo1-bringup.md`](g-demo1-bringup.md) | G2 | historical | Everything needed to bring `demo-1` up, short of the apply |
| [`h-useast4-sandbox.md`](h-useast4-sandbox.md) | H1 | historical | Retargeting the first live environment from `europe-west2` to `us-east4` |
| [`h-live-conformance.md`](h-live-conformance.md) | H2 | historical | Asking the running cloud whether the posture actually landed |
| [`i1-make-handoff.md`](i1-make-handoff.md) | I1 | historical | The `gcp-tf-*` Makefile block and the make-contract tests |
| [`j-lane-parallelism.md`](j-lane-parallelism.md) | J | **current** | Why four lanes could not coexist, and the access-path bug underneath |
| [`k-from-scratch-test-plan.md`](k-from-scratch-test-plan.md) | K | **current, maintained** | The from-scratch test plan for four lanes on both surfaces |

## How to read a historical note

1. Read the file for its reasoning. The defects and the measurements that found
   them are the value.
2. Verify any path, module or command against the tree before you act on it.
3. If a note conflicts with [`../CONTRACT.md`](../CONTRACT.md), the contract
   wins.

NOTE: `f-identity-ci.md` already carries its own superseded banner, because
`terraform/modules/ci-runner/` was absorbed elsewhere on 2026-08-20. No other
file in the series has been checked line by line against the current tree.

## Two known stale references

Both `f1-foundation.md` and [`../ISA.md`](../ISA.md) refer to
`terraform/AGENTS.md`. That file does not exist and no commit ever deleted it.
Treat those references as pointing at [`../CONTRACT.md`](../CONTRACT.md), which
holds the conventions they describe.
