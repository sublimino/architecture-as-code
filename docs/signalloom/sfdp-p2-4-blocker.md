# SFDP-P2-4 — live acceptance access blocker

Created: 2026-09-05 16:28:38+01:00
Status: fail — implementation stopped at the mandatory platform gate.
Base: `24e371ab1b2654697f9e6216645b6e9e8b034396`.

## Required outcome

Deliver a Tetragon userspace Sentinel producer, frozen InboundFlowEvent transport,
Hubble consumer, sequence/drop handling, identity enrichment, application-base
manifests, licensing determination and CI enforcement, unit/race/frostdb tests,
and live kernel-to-store proof on GKE Standard Dataplane V2. Commit delivery and
record qualified proposal errata. No fixture substitution for live acceptance.

## Decisive evidence

The explicitly scoped, read-only command:

```console
$ gcloud container clusters list --project=cp-ajm-dev --format=json
exit_status: 1
stdout: <empty>
ERROR: (gcloud.container.clusters.list) There was a problem refreshing your current auth tokens: Reauthentication failed. cannot prompt during non-interactive execution.
```

This is an authentication failure, **not an empty inventory**. No claim is made
that GKE clusters do not exist. GKE existence, Standard/Autopilot mode,
Dataplane V2, Hubble enablement and relay mTLS access remain unverified.

`kubectl config get-contexts` listed kind contexts, one EKS context, and a
generic `kubernetes-admin@kubernetes` context; current context was `kind-osramp`.
No identifiable GKE context was listed. `gcloud config get-value project`
reported `cp-ajm-dev`. No target was substituted and no credentials were changed.

## Repository and dependency checks

- Requested directory: `/home/andy/src/.worktrees/97551/osramp-demo`.
- First command `pwd` resolved to `/home/andy/.cline/worktrees/97551/osramp-demo`.
- `git merge-base --is-ancestor integration/signal-fusion-v0.1.0 HEAD` exited 0.
- HEAD was detached at the base above; initial worktree status was clean.
- Proposal was read through `obsidian-read`. P2-PRE errata declares the seam
  frozen at this base. This declaration was not promoted to runtime evidence.
- Board inspected once, read-only. P2-2 through P2-7 were active; P2-1 was done.
  Shared main.go and manifest edits were avoided. No sibling worktree was edited.

## Prompt-to-artifact audit

| Requirement | Evidence / disposition |
| --- | --- |
| Integration-only worktree | Ancestry exit 0; detached base recorded above |
| Proposal and board preflight | Read-only wrapper results inspected |
| GKE DPv2 Hubble live target | Blocked: authentication failure, inventory unverified |
| Sentinel, Hubble mapper, transport and registration | Not implemented after hard stop |
| Frozen field mapping and identity joins | Not validated; no fabricated fields |
| Sequence, duplicate, reconnect and loss tests | Not run; no passing claims |
| Policy, socket access, egress, readiness manifests | Not changed; no deployment |
| BTF, tcp_connect, Autopilot and relay mTLS checks | Not reachable; remain unverified |
| Licensing go verdict, NOTICE, SBOM and CI gates | Not produced; no go claim |
| Unit suite, race, frostdb, tidy and live parity | Not run; implementation gate stopped work |
| Durable result | This evidence-only commit; proposal failure errata and Result |

## Remediation

Principal/operator must restore usable GCP authentication and identify the
authorized GKE Standard Dataplane V2 target with enabled Hubble observability
and obtainable managed relay mTLS material. Then rerun this card from the
authorized integration base, including the remaining source-capability and
licensing gates before any deployment. Do not create an alternate cluster,
fork BPF, assume source fields, or call fixtures runtime proof.

This is an external-access prerequisite failure: `blocking_drift=no`.
No implementation changes, remote pushes, merges, PRs or runtime-board mutations
were performed.
